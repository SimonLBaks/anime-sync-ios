(() => {
  if(window.AnimeTvPage)return;
  const send=data=>window.AnimeTv?.postMessage(JSON.stringify({selection:window.AnimeSyncMediaSelection?.()||'',...data,page:location.href}));
  let route='', metadata=null, restored=false, lastSent=0, pausedForNative=false;
  const observed=new Set();
  let customState=new WeakMap();
  let nativeMode=false,catalogueSignature='',heroSignature='';
  let appBrowse=false,lastResolution='',sourceOptionsLoaded=false;
  const railStyle=document.createElement('style');
  // iOS supplies the menu in its own overlay. Keep Miruro's rail in the DOM
  // for its Settings/Login actions, without reserving either mobile or desktop space.
  railStyle.textContent='aside[style*="site-rail"]{visibility:hidden!important;pointer-events:none!important} body{padding-left:0!important;box-sizing:border-box!important} [class~="min-[900px]:pl-14"]{padding-left:0!important} header[style*="site-header"]{left:0!important} [data-anime-tv-focus]{outline:3px solid #eeeef0!important;outline-offset:3px;border-radius:8px}';
  // Website dialogs can exceed a short landscape WebView. Keep the centered
  // surface inside the viewport and let its original content scroll.
  railStyle.textContent+=' [role="dialog"],[role="alertdialog"]{box-sizing:border-box!important;max-height:calc(100vh - 32px)!important;max-height:calc(100dvh - 32px)!important;overflow-y:auto!important;overscroll-behavior-y:contain}';
  document.head.append(railStyle);
  const visible=el=>{const r=el.getBoundingClientRect();return r.width>2&&r.height>2&&getComputedStyle(el).visibility!=='hidden'&&!el.closest('aside[style*="site-rail"],[inert],[aria-hidden="true"]');};
  function navigate(code){appBrowse=true;window.AnimeTvFocus.navigate(code,()=>send({type:'sidebar'}));}
  // Native TV keys route through Java; browser/companion keyboards need the
  // same scoped navigation. Delegated widget events must not re-enter it.
  document.addEventListener('keydown',event=>{
    if(!appBrowse||nativeMode||event.defaultPrevented||event.isComposing||document.fullscreenElement||document.webkitFullscreenElement||window.AnimeTvFocus.isNavigationEvent(event))return;
    const field=event.target?.closest?.('input,textarea,[contenteditable]');
    const multiline=field&&(field.tagName==='TEXTAREA'||field.isContentEditable);
    const typing=field&&(multiline||field.tagName==='INPUT'&&!['checkbox','radio','range','button','submit','reset','file','color'].includes(field.type));
    if(event.key===' '&&typing||event.key==='Enter'&&multiline)return;
    const code={ArrowUp:19,ArrowDown:20,ArrowLeft:21,ArrowRight:22,Enter:66,' ':23}[event.key];
    if(code==null)return;
    event.preventDefault();navigate(code);
  });
  document.addEventListener('click',e=>{if(!appBrowse)return;const a=e.target.closest?.('a[href]');if(!a)return;
    const u=new URL(a.href,location.href);if(u.origin===location.origin&&/^\/(watch|info)\/[^/]+\/[^/]+/.test(u.pathname)){
      e.preventDefault();e.stopImmediatePropagation();u.pathname=u.pathname.replace(/^\/info\//,'/watch/');send({type:'browse-watch',url:u.href});}
  },true);
  let episodeControls=new Map();
  let gestureAt=0,resumeEpoch=0,resuming=false;
  for(const type of ['pointerdown','touchstart','keydown'])document.addEventListener(type,e=>{if(e.isTrusted)gestureAt=Date.now();},{capture:true,passive:true});
  const roots=()=>{
    const result=[document];
    for(let i=0;i<result.length&&i<20;i++)for(const el of result[i].querySelectorAll('*'))if(el.shadowRoot)result.push(el.shadowRoot);
    return result;
  };
  const players=()=>roots().flatMap(r=>[...r.querySelectorAll('video,strmcx-embed')]);
  const idFromPoster=p=>(p?.currentSrc||p?.src||'').match(/\/anime\/cover\/(?:large|medium)\/[bn]?x?(\d+)(?:[-.])/i)?.[1]||'';
  let synopsisWatchID='',synopsisScripts=new WeakSet(),bootstrapSynopsis='';
  function plainSynopsis(value){
    let text=value;
    if(/<\/?[a-z][^<>]*>|&(?:#\w+|[a-z]+);/i.test(text)){
      const template=document.createElement('template');
      template.innerHTML=text;
      template.content.querySelectorAll('script,style').forEach(node=>node.remove());
      template.content.querySelectorAll('br,p,div,li').forEach(node=>node.after('\n'));
      text=template.content.textContent||'';
    }
    return text.replace(/\r\n?/g,'\n').replace(/[^\S\n]+/g,' ').replace(/ *\n */g,'\n')
      .replace(/\n{3,}/g,'\n\n').trim().slice(0,6000);
  }
  function seriesSynopsis(watchID,info){
    if(!/^[A-Za-z0-9_-]{1,160}$/.test(watchID))return '';
    if(synopsisWatchID!==watchID){synopsisWatchID=watchID;synopsisScripts=new WeakSet();bootstrapSynopsis='';}
    if(bootstrapSynopsis)return bootstrapSynopsis;
    for(const script of [...document.scripts].slice(0,80)){
      if(synopsisScripts.has(script))continue;
      synopsisScripts.add(script);
      const text=script.textContent||'';
      if(text.length>150000||!text.includes('node_ids:')||!text.includes('description:'))continue;
      const start=new RegExp('\\bmedia\\s*:\\s*\\{\\s*id\\s*:\\s*"'+watchID+'"').exec(text);
      if(!start)continue;
      // Only decode a top-level JSON string on this watch route's media object.
      // The watch controls show an episode synopsis and other media have their own descriptions.
      const fields=/\bdescription\s*:\s*("(?:\\[\s\S]|[^"\\])*")|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|[{}\[\]()]/g;
      let depth=1;
      for(const field of text.slice(start.index+start[0].length).matchAll(fields)){
        if(field[1]&&depth===1){
          try{bootstrapSynopsis=plainSynopsis(JSON.parse(field[1]));}catch{}
          if(bootstrapSynopsis)return bootstrapSynopsis;
          break;
        }
        if('{[('.includes(field[0]))depth++;
        if('}])'.includes(field[0])&&!--depth)break;
      }
    }
    for(const link of info){
      const description=link.closest('div[class*="_txtWrap_"]')?.querySelector(':scope > p[class*="_description_"]');
      if(description)return plainSynopsis(description.innerText||description.textContent||'');
    }
    return '';
  }
  function pageData(){
    const u=new URL(location.href),parts=u.pathname.split('/').filter(Boolean);
    if(parts[0]!=='watch'||!parts[1]||!parts[2])return null;
    const episode=u.searchParams.get('ep')||(/^\d+(?:\.\d+)?$/.test(parts[3]||'')?parts[3]:'');
    if(!/^\d+(?:\.\d+)?$/.test(episode))return null;
    const links=[...(document.querySelector('main')||document).querySelectorAll('a[href]')];
    const info=links.filter(a=>{const x=new URL(a.href);return x.origin===u.origin&&x.pathname.split('/').filter(Boolean)[0]==='info'&&x.pathname.split('/').filter(Boolean)[1]===parts[1];});
    const poster=info.map(a=>a.querySelector('img[src*="/anime/cover/"]')).find(Boolean);
    const external=new Set(links.map(a=>{const x=new URL(a.href);return x.hostname==='anilist.co'?x.pathname.match(/^\/anime\/(\d+)(?:\/|$)/)?.[1]:'';}).filter(Boolean));
    let id=info.length?(external.size===1?[...external][0]:idFromPoster(poster)):'';
    if(idFromPoster(poster)&&id!==idFromPoster(poster))id='';
    if(!/^\d+$/.test(id))return null;
    const description=seriesSynopsis(parts[1],info);
    u.hash='';
    return {site:'miruro',anime_id:id,slug:parts[2],episode,title:info.find(a=>a.closest('h1,h2,h3')||a.classList.contains('watch-anime-title'))?.textContent.trim()||poster?.alt||document.title,
      watch_url:u.href,poster_url:poster?.currentSrc||poster?.src||'',...(description?{description}:{})};
  }
  function resolveSearch(){
    if(location.pathname!=='/search')return;
    const params=new URLSearchParams(location.hash.slice(1)),id=params.get('anime-sync-id'),ep=params.get('anime-sync-ep');
    if(!/^\d+$/.test(id||'')||!/^\d+(?:\.\d+)?$/.test(ep||''))return;
    const matches=new Map();
    for(const a of (document.querySelector('main')||document).querySelectorAll('a[href]')){
      const u=new URL(a.href);if(u.origin!==location.origin||!/^\/(watch|info)\/[^/]+\/[^/]+\/?$/.test(u.pathname))continue;
      const card=a.closest('[data-cover-card]')||a;
      if(idFromPoster(card.querySelector('img[src*="/anime/cover/"]'))===id){u.pathname=u.pathname.replace(/^\/info\//,'/watch/');matches.set(u.pathname,u);}
    }
    if(matches.size===1){const u=[...matches.values()][0];u.search=new URLSearchParams({ep}).toString();
      if(params.has('anime-sync-t'))u.hash=new URLSearchParams({'anime-sync-t':params.get('anime-sync-t')});
      // Let Android own embedded navigation; redirecting the still-loading search
      // document can leave its watch page unfinished in a background WebView.
      if(typeof window.AnimeTv?.postMessage==='function'){
        const key=location.href+'\n'+u.href;if(key!==lastResolution){lastResolution=key;send({type:'resolved-watch',url:u.href,anime_id:id,episode:ep});}
      }else location.replace(u.href);}
  }
  let suggestionSignature='';
  const searchBootstrap=new WeakMap();
  const searchFields={
    format:/^(?:TV(?:[ _]SHORT)?|OVA|ONA|MOVIE|SPECIAL|MUSIC)$/,
    season_year:/^[12]\d{3}$/,
    episode_count:/^[1-9]\d{0,4}$/,
    average_score:/^(?:[1-9]?\d(?:\.\d{1,2})?|100(?:\.0{1,2})?)$/
  };
  function searchResultMetadata(ids){
    const matches=new Map();
    for(const script of [...document.scripts].slice(0,80)){
      const text=script.textContent||'';
      if(text.length>2000000||!text.includes('node_ids:')||!text.includes('average_score:'))continue;
      let cached=searchBootstrap.get(script);
      if(cached?.text!==text){
        cached={text,entries:new Map()};searchBootstrap.set(script,cached);
        // The visible grid owns ranking and navigation. Read only display fields
        // from its public bootstrap rows, without executing the source script.
        for(const row of text.matchAll(/\{\s*id\s*:\s*"([A-Za-z0-9_-]{1,160})"\s*,/g)){
          const fields=/\b(format|season_year|episode_count|average_score)\s*:\s*("[A-Z0-9_ ]{1,24}"|\d{1,5}(?:\.\d{1,2})?|null)|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|[{}\[\]()]/g;
          fields.lastIndex=row.index+row[0].length;
          const values={...cached.entries.get(row[1])};let depth=1;
          for(let field;(field=fields.exec(text));){
            if(field[1]){
              const value=field[2].replace(/^"|"$/g,'');
              if(depth===1&&searchFields[field[1]].test(value))values[field[1]]=value;
              continue;
            }
            if('{[('.includes(field[0]))depth++;
            if('}])'.includes(field[0])&&!--depth)break;
          }
          if(Object.keys(values).length)cached.entries.set(row[1],values);
        }
      }
      for(const id of ids){
        const values=cached.entries.get(id);
        if(values)matches.set(id,{...matches.get(id),...values});
      }
    }
    return matches;
  }
  function searchSuggestions(){
    if(!nativeMode||location.pathname!=='/search'||!/^#anime-sync-suggestions=[1-9]\d{0,18}$/.test(location.hash))return;
    const page=new URL(location.href),params=[...page.searchParams];
    const query=params.length===1&&params[0][0]==='q'?params[0][1].trim():'';
    if(!query||query.length>200)return;
    const label='Results for "'+query+'"';
    const paragraphs=[...document.querySelectorAll('p')];
    const current=paragraphs.some(p=>p.textContent.trim()===label);
    const grid=current?document.querySelector('.browse-grid'):null;
    const cards=new Map();
    for(const anchor of [...(grid?.querySelectorAll(':scope > a[href]')||[])].slice(0,32)){
      const url=new URL(anchor.href,page),route=url.pathname.match(/^\/(?:info|watch)\/([A-Za-z0-9_-]{1,160})\/[^/]{1,240}\/?$/);
      if(!route||url.origin!==page.origin||url.protocol!=='https:'||url.username||url.password)continue;
      const img=anchor.querySelector('img.card-image,img[data-cover-image],img[src*="/anime/cover/"]');
      const title=(img?.alt?.trim()||anchor.querySelector('p')?.textContent.trim()||'').slice(0,240);
      if(!title||cards.has(route[1]))continue;
      let poster='';
      const source=img?.currentSrc||img?.getAttribute('src');
      if(source)try{
        const artwork=new URL(source,page);
        if(artwork.protocol==='https:'&&!artwork.username&&!artwork.password)poster=artwork.href;
      }catch{}
      url.pathname=url.pathname.replace(/^\/info\//,'/watch/');url.search='';url.hash='';
      cards.set(route[1],{anchor,title,poster,url:url.href});
      if(cards.size===6)break;
    }
    const metadata=cards.size?searchResultMetadata([...cards.keys()]):new Map();
    const items=[...cards].map(([id,{anchor,title,poster,url}])=>{
      const fields=metadata.get(id)||{};
      const spans=[...anchor.querySelectorAll('span')].map(el=>el.textContent.trim());
      const year=fields.season_year||spans.find(text=>searchFields.season_year.test(text))||'';
      const type=fields.format||spans.find(text=>/^(?:TV(?: short)?|OVA|ONA|Movie|Special|Music)$/i.test(text))||'';
      const format=/^(?:TV(?:[ _]SHORT)?|OVA|ONA|MOVIE|SPECIAL|MUSIC)$/i.test(type)?type.replace(/_/g,' ').toUpperCase():'';
      const episode_count=fields.episode_count||'';
      const score=fields.average_score===undefined?'':String(Math.round(Number(fields.average_score)));
      return {title,poster,url,year,format,episode_count,score};
    });
    const empty=current&&paragraphs.some(p=>p.textContent.trim()==='No matching titles');
    const loading=!items.length&&!empty;
    const payload={type:'search-suggestions',query,items,loading,page:page.href};
    const signature=JSON.stringify(payload);
    if(signature!==suggestionSignature){suggestionSignature=signature;send(payload);}
  }
  function catalogue(){
    const featured=document.querySelector('section.hero');
    if(featured){
      const logo=featured.querySelector('img.title-logo');
      const backdrop=[...featured.querySelectorAll('.backdrop')].find(el=>Number(el.style.opacity||'1')>.5)?.querySelector('img');
      const link=featured.querySelector('a[href*="/watch/"]');
      const hero={title:logo?.alt||featured.querySelector('h1')?.textContent.trim()||'',logo:logo?.src||'',backdrop:backdrop?.currentSrc||backdrop?.src||'',
        description:featured.querySelector('.desc')?.textContent.trim()||'',meta:[...featured.querySelectorAll('.pill')].map(p=>p.textContent.trim()).join('  ·  '),url:link?.href||''};
      const signature=JSON.stringify(hero);if(hero.title&&signature!==heroSignature){heroSignature=signature;send({type:'hero',hero});}
    }
    const read=scope=>{
      const unique=new Map();
      for(const a of scope.querySelectorAll('a[href]')){
        const u=new URL(a.href,location.href);if(u.origin!==location.origin||!/^\/(watch|info)\/[^/]+\/[^/]+/.test(u.pathname))continue;
        const card=a.closest('[data-cover-card]')||a;
        const img=card.querySelector('img[data-cover-image],img[src*="/anime/cover/"]')||a.querySelector('img');
        if(!img)continue;const poster=img.currentSrc||img.src;if(!poster?.startsWith('https://'))continue;
        const title=a.getAttribute('aria-label')?.trim()||img.alt?.trim()||card.querySelector('h2,h3,[class*="title"]')?.textContent?.trim()||a.textContent.trim();if(!title)continue;
        u.pathname=u.pathname.replace(/^\/info\//,'/watch/');
        const badge=a.textContent.trim().replace(title,'').replace(/\s+/g,' ').slice(0,55);
        if(!unique.has(u.pathname))unique.set(u.pathname,{title,poster,url:u.href,badge});
      }return [...unique.values()].slice(0,24);
    };
    const groups=[];
    for(const section of document.querySelectorAll('section')){
      const title=section.querySelector('h2,h3')?.textContent?.trim();if(!title)continue;
      const items=read(section);if(items.length)groups.push({title,items});
    }
    if(!groups.length){const items=read(document);if(items.length)groups.push({title:location.pathname==='/search'?'Search results':document.querySelector('h1')?.textContent.trim()||'Discover',items});}
    const text=(document.querySelector('main')||document.body).innerText||'';
    const empty=/no (?:anime|results|history|episodes|items)|history is empty|haven.t watched/i.test(text);
    const loading=!groups.length&&!empty&&(document.readyState!=='complete'||[...document.querySelectorAll('[aria-busy="true"],[role="progressbar"],[class*="skeleton"],.animate-pulse')].some(visible)||/\b(?:Loading|Searching)(?:\s+(?:anime|results|history|episodes))?\s*[.…]/i.test(text));
    const message=loading?'Loading Miruro…':location.pathname==='/search'?'No results found. Try another search.':location.pathname==='/history'?'No Miruro history yet. Your saved progress is in Anime Sync.':'No titles available here. Try Reload in Settings.';
    const payload={type:'catalogue',groups,loading,message,page:location.href};
    const signature=JSON.stringify(payload);if(signature!==catalogueSignature){catalogueSignature=signature;send(payload);}
  }
  let seasonSignature='';
  function watchSeasonID(url){
    return url.pathname.match(/^\/watch\/([A-Za-z0-9_-]{1,160})\/[^/]{1,240}\/?$/)?.[1]||'';
  }
  function seasonChoices(){
    if(!nativeMode||!metadata)return;
    const page=new URL(location.href),currentID=watchSeasonID(page);
    if(!currentID)return;
    let seasons=[];
    for(const section of document.querySelectorAll('section[aria-label="Seasons"]')){
      if(section.getAttribute('aria-busy')==='true')continue;
      const choices=new Map();
      let inconsistent=false;
      for(const card of [...section.querySelectorAll('a[href][aria-label]')].slice(0,64)){
        const label=card.getAttribute('aria-label').trim().match(/^Watch\s+(.+)$/i)?.[1].replace(/\s+/g,' ');
        if(!label||label.length>80)continue;
        let url;
        try{url=new URL(card.getAttribute('href'),page);}catch{continue;}
        const routeID=watchSeasonID(url);
        if(!routeID||url.protocol!=='https:'||url.origin!==page.origin||url.username||url.password)continue;
        const episode=url.searchParams.getAll('ep');
        if(episode.length>1||episode.length&&!/^\d{1,5}(?:\.\d{1,3})?$/.test(episode[0]))continue;
        url.search=episode.length?new URLSearchParams({ep:episode[0]}).toString():'';
        url.hash='';
        const selected=routeID===currentID;
        if(card.getAttribute('aria-current')==='page'&&!selected){inconsistent=true;break;}
        const image=card.querySelector('img'),source=image?.currentSrc||image?.getAttribute('src');
        let poster='',id='';
        if(source){
          try{
            const artwork=new URL(source,page);
            if(artwork.protocol==='https:'&&!artwork.username&&!artwork.password){
              poster=artwork.href;
              if(artwork.hostname.endsWith('.anilist.co'))id=idFromPoster({src:poster});
            }
          }catch{}
        }
        const year=[...card.querySelectorAll('*')].map(el=>!el.childElementCount?el.textContent.trim():'').find(value=>/^\d{4}$/.test(value))||'';
        const title=(card.getAttribute('title')||'').trim().slice(0,240);
        const existing=choices.get(routeID);
        if(existing&&existing.url!==url.href){inconsistent=true;break;}
        if(!existing)choices.set(routeID,{id,label,title,year,poster,url:url.href,selected});
      }
      // During SPA navigation, the previous page's panel may still be present.
      // Its cards are only useful if the current watch entry belongs to the group.
      if(!inconsistent&&choices.has(currentID)&&choices.size>1&&choices.size<=32){seasons=[...choices.values()];break;}
    }
    const signature=JSON.stringify([page.href,seasons]);
    if(signature!==seasonSignature){seasonSignature=signature;send({type:'seasons',seasons});}
  }
  let episodeSignature='',serializedEpisodes=[],episodeVersion=0,lastEpisodeVersion='';
  const episodeScripts=new WeakSet();
  function readSerializedEpisodes(){
    for(const script of [...document.scripts].slice(0,80)){
      const text=script.textContent||'';
      if(episodeScripts.has(script)||text.length>2000000||!text.includes('episodes:')||!/^\s*__sveltekit_[\w$]+\.resolve\(/.test(text))continue;
      episodeScripts.add(script);
      const name=text.match(/^\s*(__sveltekit_[\w$]+)\.resolve\(/)?.[1];if(!name)continue;
      try{
        // Read the same public, already-executed SSR data callback in a capture
        // object. No framework state, accounts or source configuration is exported.
        Function(name,'"use strict";'+text)({resolve(_id,callback){
          const value=callback();if(!Array.isArray(value))return;
          const found=value.find(group=>Array.isArray(group?.episodes));if(!found)return;
          const items=found.episodes.slice(0,3000).filter(item=>item&&typeof item.title==='string'&&/^\d+(?:\.\d+)?$/.test(String(item.number))&&Number(item.number)>=0);
          if(items.length){episodeVersion++;serializedEpisodes=items.map(item=>({id:String(item.id||item.number).slice(0,80),number:String(Number(item.number)),title:item.title.slice(0,300)}));}
        }});
      }catch{}
    }
  }
  function episodes(){
    if(!nativeMode||!metadata)return;
    readSerializedEpisodes();
    const version=metadata.episode+':'+episodeVersion;if(serializedEpisodes.length&&version===lastEpisodeVersion)return;lastEpisodeVersion=version;
    const unique=new Map();
    for(const item of serializedEpisodes)unique.set(item.number,{...item,label:'Episode '+item.number});
    const scope=document.querySelector('[data-ep-scroll]');
    if(!scope&&!serializedEpisodes.length){const drawer=document.querySelector('button.watch-drawer-trigger[aria-expanded="false"]');if(drawer&&!drawer.dataset.animeTvOpened){drawer.dataset.animeTvOpened='1';drawer.click();}}
    const controls=[...(scope||document.querySelector('[data-ep-scroll]')||document).querySelectorAll('button,a[href]')];
    episodeControls=new Map();
    for(const el of controls){
      const text=(el.getAttribute('aria-label')||el.textContent||'').trim();
      const match=text.match(/^(?:Episode\s+|EP\s*)?(\d+(?:\.\d+)?)(?:\s*[-·:]\s*.*)?$/i);if(!match||text.length>100)continue;
      const number=String(Number(match[1]));let url;
      try{url=new URL(el.href,location.href);if(url.origin!==location.origin||url.pathname!==location.pathname||url.searchParams.get('ep')!==number)continue;}catch{continue;}
      const existing=unique.get(number),title=(el.getAttribute('title')||'').trim();
      const item=existing||{id:number,number,label:'Episode '+number,title:''};if(!item.title&&title&&!/^(?:Episode\s+|EP\s*)?\d+(?:\.\d+)?$/i.test(title))item.title=title.slice(0,300);
      unique.set(number,item);episodeControls.set(item.id,el);
    }
    const list=[...unique.values()].sort((a,b)=>Number(a.number)-Number(b.number)).map(item=>{const url=new URL(location.href);url.searchParams.set('ep',item.number);url.hash='';return{...item,url:url.href,selected:Number(item.number)===Number(metadata.episode)};});
    const payload={type:'episodes',episodes:list,complete:serializedEpisodes.length>0};
    const signature=JSON.stringify(payload);if(list.length&&signature!==episodeSignature){episodeSignature=signature;send(payload);}
  }
  let sourceChoiceSerial=0;
  const sourceOptions=new Map();
  const choiceLabel=el=>(el.getAttribute('aria-label')||el.innerText||el.textContent||'').trim().replace(/\s+/g,' ');
  const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  async function sourceMenu(name){
    const trigger=document.querySelector('main button[aria-label="'+name+'"]')||document.querySelector('button[aria-label="'+name+'"]');
    if(!trigger)return null;
    const alreadyOpen=trigger.getAttribute('aria-expanded')==='true';if(!alreadyOpen)trigger.click();
    let menu=null;
    for(let attempt=0;attempt<10;attempt++){
      // Svelte closes the previous portal asynchronously. Wait for this trigger's
      // owned menu instead of mistaking a closing Audio menu for Provider.
      await delay(attempt?60:0);
      const owned=trigger.getAttribute('aria-controls');menu=owned?document.getElementById(owned):null;
      if(menu&&menu.querySelector('[role="menuitem"],[role="menuitemradio"]'))break;
    }
    const items=menu?[...menu.querySelectorAll('[role="menuitem"],[role="menuitemradio"]')].filter(el=>visible(el)&&el.getAttribute('aria-disabled')!=='true'):[];
    return {trigger,items,close(){if(!alreadyOpen&&trigger.getAttribute('aria-expanded')==='true')trigger.click();}};
  }
  async function collectSourceChoices(){
    const page=location.href,serial=++sourceChoiceSerial;sourceOptions.clear();const groups=[];send({type:'source-choices-status',loading:true});
    for(const name of ['Audio','Provider']){
      const menu=await sourceMenu(name);if(serial!==sourceChoiceSerial||page!==location.href){menu?.close();return;}
      if(menu){const items=menu.items.map((el,index)=>{
        const label=choiceLabel(el).slice(0,160),id=name+':'+encodeURIComponent(label);sourceOptions.set(id,{name,label,page});
        return {id,label,selected:el.getAttribute('aria-checked')==='true'||el.getAttribute('data-state')==='checked'||!!el.querySelector('svg.lucide-check')||label===choiceLabel(menu.trigger)||label.split(' ')[0]===choiceLabel(menu.trigger)&&menu.items.filter(item=>choiceLabel(item).split(' ')[0]===choiceLabel(menu.trigger)).length===1};
      }).filter(item=>item.label);menu.close();if(items.length)groups.push({name,items});}
    }
    if(serial===sourceChoiceSerial&&page===location.href)send({type:'source-choices',groups});
  }
  async function selectSource(id,ticket){
    const option=sourceOptions.get(id);if(!option||option.page!==location.href)return false;
    const page=location.href,serial=++sourceChoiceSerial,menu=await sourceMenu(option.name);
    if(!menu||page!==location.href||serial!==sourceChoiceSerial){menu?.close();return false;}
    const matches=menu.items.filter(el=>choiceLabel(el)===option.label);
    if(matches.length!==1){menu.close();return false;}
    window.AnimeSyncMediaReset?.(ticket);observed.clear();matches[0].click();
    send({type:'source-selected',id,label:option.label,selection:ticket});setTimeout(()=>{if(serial===sourceChoiceSerial)collectSourceChoices();},100);return true;
  }
  function metrics(v,detail={},event=''){
    const previous=customState.get(v)||{};
    const current={...previous,...detail};customState.set(v,current);
    const position=Number(v.tagName==='VIDEO'?v.currentTime:current.currentTime??current.time),duration=Number(v.tagName==='VIDEO'?v.duration:current.duration);
    const playing=v.tagName==='VIDEO'?!v.paused&&!v.ended:current.state==='playing';
    if(!nativeMode&&metadata&&(event==='play'||event==='strmcx-state-change'&&playing)){
      pausedForNative=false;send({type:'playback-start',metadata,explicit:Date.now()-gestureAt<10000});
    }
    if(!metadata||!Number.isFinite(position)||!Number.isFinite(duration)||duration<=0||pausedForNative)return;
    const requested=Number(new URLSearchParams(location.hash.slice(1)).get('anime-sync-t'));
    if(!restored&&requested>=5&&requested<duration-5){
      if(typeof v.seek==='function')v.seek(requested);else v.currentTime=requested;restored=true;return;
    }
    restored=true;
    const ended=!!v.ended||current.ended===true;
    const paused=!!v.paused||current.state==='paused';
    if(!nativeMode&&paused&&(event==='pause'||event==='strmcx-state-change'))send({type:'playback-stop',metadata,position,duration,ended});
    if(Date.now()-lastSent<5000&&!paused&&!ended)return;lastSent=Date.now();
    send({type:'progress',metadata,position,duration,ended,playing});
  }
  function scan(){
    if(route!==location.href){resumeEpoch++;resuming=false;if(!nativeMode)pausedForNative=false;route=location.href;metadata=null;restored=false;observed.clear();customState=new WeakMap();send({type:'route',url:route});}
    resolveSearch();const next=pageData();
    if(next){const {description,...identity}=next;metadata=identity;send({type:'metadata',metadata:next});}
    catalogue();searchSuggestions();episodes();seasonChoices();if(nativeMode&&metadata&&!sourceOptionsLoaded&&document.querySelector('button[aria-label="Provider"]')){sourceOptionsLoaded=true;collectSourceChoices();}
    if(metadata&&!window.AnimeSyncMediaSelection?.())for(const root of roots())for(const el of root.querySelectorAll('video,source,track')){
      if(el.tagName==='TRACK'&&el.kind!=='subtitles'&&el.kind!=='captions')continue;
      const url=el.currentSrc||el.src;if(!url||!url.startsWith('https://'))continue;
      const k=el.tagName+url;if(observed.has(k))continue;observed.add(k);
      send({type:el.tagName==='TRACK'?'subtitle':'source',url,label:el.label||'',language:el.srclang||'en',confirmed:el.tagName==='VIDEO'});
    }
    for(const v of players()){
      if(v.dataset.animeTvObserved)continue;v.dataset.animeTvObserved='1';
      for(const name of ['play','loadedmetadata','timeupdate','pause','ended','strmcx-time-update','strmcx-duration-change','strmcx-state-change','strmcx-ended'])
        v.addEventListener(name,e=>metrics(v,{...(e.detail||{}),...(name==='strmcx-ended'?{ended:true}:{}),...(name==='strmcx-time-update'?{ended:false}:{})},name));
      metrics(v);
    }
  }
  function resumeBrowserTo(position,autoplay=false){
    if(!Number.isFinite(position)||position<0)return;
    const list=players(),primary=list.find(v=>v.tagName==='STRMCX-EMBED')||list[0];if(!primary)return;
    const epoch=++resumeEpoch,started=Date.now();resuming=true;pausedForNative=true;restored=true;
    for(const v of list){if(typeof v.seek==='function')v.seek(position);else v.currentTime=position;}
    const acknowledge=()=>{if(epoch!==resumeEpoch)return;const state=customState.get(primary)||{};
      const actual=Number(primary.tagName==='VIDEO'?primary.currentTime:state.currentTime??state.time??primary.currentTime);
      if(Number.isFinite(actual)&&Math.abs(actual-position)<=2+(Date.now()-started)/1000){resuming=false;pausedForNative=false;
        if(autoplay){try{const result=primary.play?.();result?.catch?.(()=>send({type:'playback-resume-failed'}));}catch{send({type:'playback-resume-failed'});}}return;}
      if(Date.now()-started<5000){setTimeout(acknowledge,40);return;}
      resuming=false;for(const v of list)v.pause?.();send({type:'playback-resume-failed'});
    };acknowledge();
  }
  window.AnimeTvPage={
    navigate,
    back(){return window.AnimeTvFocus.back();},
    browseMode(value){appBrowse=!!value;},
    openPanel(name){let attempts=0;const open=()=>{const button=document.querySelector('aside[style*="site-rail"] button[aria-label="'+name+'"]');
      if(button){button.click();setTimeout(()=>navigate(0),200);}else if(++attempts<10)setTimeout(open,200);};setTimeout(open,300);},
    nativeMode(value){nativeMode=!!value;if(nativeMode){resumeEpoch++;resuming=false;}if(!nativeMode)pausedForNative=false;catalogueSignature='';heroSignature='';suggestionSignature='';scan();},
    selectEpisode(id){episodeControls.get(id)?.click();},
    sourceChoices:collectSourceChoices,selectSource,
    pause(){resumeEpoch++;resuming=false;for(const v of players()){if(typeof v.pause==='function')v.pause();if(!nativeMode&&metadata)metrics(v,{state:'paused'},'pause');}pausedForNative=true;},
    handoff(id){
      if(resuming){send({type:'handoff-ready',id,paused:false});return;}
      const sample=v=>{const state=customState.get(v)||{};return {position:Number(v.tagName==='VIDEO'?v.currentTime:state.currentTime??state.time??v.currentTime),duration:Number(v.tagName==='VIDEO'?v.duration:state.duration??v.duration),paused:typeof v.paused==='boolean'?v.paused:state.state==='paused',ended:!!v.ended||state.ended===true};};
      const player=players().find(v=>{const s=sample(v);return Number.isFinite(s.duration)&&s.duration>0;});
      if(!player||!metadata){send({type:'handoff-ready',id,paused:false});return;}
      pausedForNative=true;player.pause?.();let attempts=0;
      const finish=()=>{const state=sample(player);if(!state.paused&&++attempts<35){setTimeout(finish,40);return;}send({type:'handoff-ready',id,metadata,...state});};finish();
    },
    resumeBrowser:resumeBrowserTo,
    command(cmd,arg){if(cmd==='play'||cmd==='toggle')gestureAt=Date.now();
      if(cmd==='seek_to'){resumeBrowserTo(Math.max(0,arg));return;}
      if(cmd==='seek'){const list=players(),v=list.find(x=>x.tagName==='STRMCX-EMBED')||list[0];if(v){const state=customState.get(v)||{};resumeBrowserTo(Math.max(0,Number(v.currentTime??state.currentTime??state.time??0)+arg));}return;}
      for(const v of players()){
        if(cmd==='toggle'){const paused=typeof v.paused==='boolean'?v.paused:customState.get(v)?.state!=='playing';if(paused)v.play?.();else v.pause?.();}
        if(cmd==='play')v.play?.();if(cmd==='pause')v.pause?.();
      }},
    text(text){const el=document.activeElement;if(!el?.matches('input,textarea'))return;
      const proto=el instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto,'value')?.set?.call(el,text);el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));}
  };
  for(const name of ['pushState','replaceState']){const original=history[name];history[name]=function(...args){const result=original.apply(this,args);queueMicrotask(scan);return result;};}
  addEventListener('popstate',scan);addEventListener('hashchange',scan);
  scan();setInterval(scan,1200);
})();
