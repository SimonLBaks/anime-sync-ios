(() => {
  // This channel can report URLs only. Native code ignores control/metadata fields here.
  if (window.__animeSyncResourceObserver) return;
  window.__animeSyncResourceObserver = true;
  const nonce = __ANIME_SYNC_NONCE__;
  const nativeMode = __ANIME_SYNC_NATIVE__;
  let selection='';
  window.AnimeSyncMediaReset=value=>{selection=String(value||'').slice(0,80);};
  window.AnimeSyncMediaSelection=()=>selection;
  const report = (value,ticket=selection) => {try{window.webkit?.messageHandlers?.providerResource?.postMessage({nonce,data:JSON.stringify({...value,selection:ticket,page:location.href,requestPage:location.href})});}catch{}};
  const send = (url, kind = 'source', mime = '', requestPage = location.href, mediaElement = false, details = {}, ticket = selection) => {
    try {
      const u = new URL(url, location.href);
      if (u.protocol !== 'https:' || u.username || u.password) return;
      const ext = u.pathname.toLowerCase();
      // Safari players often fetch WebVTT through an extensionless URL, then
      // expose only a blob URL on the TRACK element.
      const subtitle = kind === 'subtitle' || /\.(vtt|srt|ass|ssa|ttml)$/.test(ext) || /^(?:text\/(?:vtt|srt|x-(?:ssa|ass))|application\/(?:ttml\+xml|x-(?:subrip|ssa|ass)))(?:\s*;|\s*$)/i.test(mime);
      if (!subtitle && !mediaElement && !/\.(m3u8|mp4|m4v|mpd|webm)$/.test(ext) && !/^(application\/(?:vnd\.apple\.mpegurl|x-mpegurl|dash\+xml)|video\/(?:mp4|webm))/i.test(mime)) return;
      const referer=new URL(details.frameURL||location.href);
      window.webkit?.messageHandlers?.providerResource?.postMessage({nonce, data:JSON.stringify({
        type:subtitle ? 'subtitle' : 'source', url:u.href, mime, mediaElement,
        configured:details.configured===true,
        label:String(details.label||'').slice(0,120),language:String(details.language||'').slice(0,20),
        page:location.href, requestPage,selection:ticket,
        headers:{Referer:referer.href,Origin:referer.origin,'User-Agent':navigator.userAgent}
      })});
    } catch {}
  };
  const fetchOriginal = window.fetch;
  if (fetchOriginal) window.fetch = function(...args) {
    const page = location.href,ticket=selection;
    return fetchOriginal.apply(this,args).then(response => {
      send(response.url,'source',response.headers.get('Content-Type')||'',page,false,{},ticket); return response;
    });
  };
  const openOriginal = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(...args) {
    const page = location.href,ticket=selection;
    this.addEventListener('load',()=>send(this.responseURL,'source',this.getResponseHeader('Content-Type')||'',page,false,{},ticket),{once:true});
    return openOriginal.apply(this,args);
  };
  try {
    const observe = entries => {if(!selection)entries.forEach(entry => send(entry.name));};
    observe(performance.getEntriesByType('resource'));
    new PerformanceObserver(list=>observe(list.getEntries())).observe({entryTypes:['resource']});
  } catch {}
  // The public embed API retains the HTTPS track URLs and language labels;
  // inside its frame those tracks may already have become opaque blob URLs.
  if(window.customElements)customElements.whenDefined('strmcx-embed').then(()=>{
    const prototype=customElements.get('strmcx-embed')?.prototype,original=prototype?.setSession;
    if(typeof original!=='function')return;
    const revisions=new WeakMap(),selections=new WeakMap();
    prototype.setSession=function(...args){
      const accepted=original.apply(this,args);
      const session=args[0],revision=session?.revision,previous=revisions.get(this);
      // The SDK also returns true for ignored older revisions.
      if(accepted===true&&Number.isSafeInteger(revision)&&revision>=0&&(previous===undefined||revision>=previous)&&
         !(selection!==selections.get(this)&&previous!==undefined&&revision<=previous))try{
        revisions.set(this,revision);selections.set(this,selection);
        report({type:'source-session',sessionID:String(session.id||'').slice(0,200),revision,status:String(session.status||'').slice(0,40)});
        const frameURL=this.shadowRoot?.querySelector('iframe')?.src||location.href;
        if(session.source?.kind==='direct')send(session.source.url,'source',session.source.type||'',location.href,true,{frameURL,configured:true});
        for(const track of (Array.isArray(session.tracks)?session.tracks:[]).slice(0,32)){
          if(track&&(track.kind==='subtitles'||track.kind==='captions'))send(track.src,'subtitle','',location.href,false,{label:track.label,language:track.language,frameURL,configured:true});
        }
      }catch{}
      return accepted;
    };
  }).catch(()=>{});
  const roots = () => {const result=[document];for(let i=0;i<result.length&&i<20;i++)for(const node of result[i].querySelectorAll('*'))if(node.shadowRoot)result.push(node.shadowRoot);return result;};
  const quiet = node => {if(nativeMode&&(node.tagName==='VIDEO'||node.tagName==='AUDIO')){node.muted=true;node.defaultMuted=true;node.volume=0;node.setAttribute?.('muted','');node.setAttribute?.('playsinline','');}};
  if(nativeMode){
    // Native discovery may initialize the hidden embed without a web touch. Its
    // separate document stays silent even if the website later changes volume.
    for(const [name,value]of [['muted',true],['volume',0]]){const descriptor=Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,name);if(descriptor?.set&&descriptor.configurable)Object.defineProperty(HTMLMediaElement.prototype,name,{...descriptor,set(){descriptor.set.call(this,value);}});}
    const play=HTMLMediaElement.prototype.play;HTMLMediaElement.prototype.play=function(...args){quiet(this);const result=play.apply(this,args);result?.catch?.(error=>{if(error?.name==='NotAllowedError')report({type:'media-status',phase:'gesture-required'});});return result;};
    new MutationObserver(records=>{for(const record of records)for(const node of record.addedNodes){quiet(node);for(const media of node.querySelectorAll?.('video,audio')||[])quiet(media);}}).observe(document,{childList:true,subtree:true});
  }
  const seen = new Set();
  const scan = () => {
    if(selection)return; // Selected sources use request-captured or configured offers.
    for(const root of roots())for(const node of root.querySelectorAll('video,audio,source,track')){
      quiet(node);
      const url=node.currentSrc||node.src;if(!url)continue;
      const key=node.tagName+' '+url+' '+(node.label||'')+' '+(node.srclang||'');if(seen.has(key))continue;seen.add(key);
      const mediaElement=node.tagName==='VIDEO'||node.tagName==='AUDIO'||node.tagName==='SOURCE'&&node.parentElement?.matches('video,audio');
      send(url,node.tagName==='TRACK'?'subtitle':'source',node.type||'',location.href,!!mediaElement,{label:node.label,language:node.srclang});
    }
  };
  scan();setInterval(scan,1000);
})();
