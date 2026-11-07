(() => {
  if (window.AnimeTvDashboard) { window.AnimeTvDashboard.snapshot?.(true); return; }
  const viewport=document.querySelector('meta[name=viewport]');
  if(viewport)viewport.content='width=device-width, initial-scale=1, maximum-scale=1';
  const send = value => window.AnimeTv?.postMessage(JSON.stringify(value));
  const style = document.createElement('style');
  style.textContent = `
    :focus-visible, [data-tv-focus] { outline: 3px solid #5de0c2 !important; outline-offset: 4px; }
    .app { width: min(1400px, calc(100% - 64px)); }
    .button { min-height: 46px; }
    html { scroll-padding: 100px 30px; }
    html, body { width: 100%; max-width: 100%; overflow-x: clip; }
    .app, .topbar, .hero, .discovery, .discovery > div { min-width: 0; }
    .rail { max-width: 100%; overscroll-behavior-x: contain; }
    :focus { scroll-margin-block: 90px 24px; }
  `;
  document.head.append(style);
  window.AnimeTvNav = {
    move(direction){window.AnimeTvFocus.navigate({up:19,down:20,left:21,right:22}[direction],()=>send({type:'sidebar'}));},
    back(){return window.AnimeTvFocus.back();},
    text(value){window.AnimeTvFocus.text(value);}
  };
  document.addEventListener('keydown',e=>{
    if(window.AnimeTvFocus.isNavigationEvent(e))return;
    const target=e.composedPath()[0];if((e.key===' '||e.key==='Enter')&&target?.matches('textarea,[contenteditable="true"]')||e.key===' '&&target?.matches('input'))return;
    const code={ArrowUp:19,ArrowDown:20,ArrowLeft:21,ArrowRight:22,Enter:66,' ':23}[e.key];
    if(code){e.preventDefault();window.AnimeTvFocus.navigate(code,()=>send({type:'sidebar'}));}
  },true);
  document.addEventListener('click',e=>{
    const a=e.target.closest('a[href]');if(!a)return;
    const u=new URL(a.href,location.href);
    if (!/^https:\/\/(www\.)?miruro\.(cx|to)(\/|$)/.test(u.href)) return;
    e.preventDefault();e.stopImmediatePropagation();
    // The server's current stable AniList identity remains authoritative.
    let item=null;
    try {
      const row=a.closest('[data-id]');
      item=state.items.find(i=>i.watch_url===u.href)||null;
      if(!item){
        const clean=x=>{const v=new URL(x);v.hash='';return v.href;};
        item=state.items.find(i=>clean(i.watch_url)===clean(u.href))||null;
      }
    } catch {}
    send({type:'watch',url:u.href,item});
  },true);
  let librarySignature='',reportedAuthentication=false,reportedLoading=false;
  function snapshot(force=false){try{
    if(!state.authenticated)return;
    if(force||!reportedAuthentication){reportedAuthentication=true;send({type:'authenticated'});}
    const list=document.querySelector('#list');
    // Authentication finishes before the backend's parallel library requests.
    // An initial empty array or an in-flight refresh is not a complete library.
    const pending=state.loadInFlight||state.mutationInFlight||!Array.isArray(state.series)||!list||!list.children.length;
    if(pending){if(force||!reportedLoading){reportedLoading=true;send({type:'library-status',loading:true});}return;}
    const cards=state.series.map(s=>{const e=latestTrackedEpisode(s),next=e?.completed&&!s.is_completed?s.next_episode:null;return {
      key:seriesKey(s),title:s.title,poster:posterUrl(s),url:seriesActionUrl(s,e),episode:next?.episode||e?.episode||'',progress:next?0:e?.progress||0,
      next_url:s.next_episode?.watch_url||'',next_episode:s.next_episode?.episode||'',
      continuing:!!e&&!s.is_completed&&s.status!=='dropped'&&!isUpToDateSeries(s)&&!isNewEpisodeSeries(s),has_new:isNewEpisodeSeries(s)};});
    const signature=JSON.stringify(cards);
    if(force||signature!==librarySignature){librarySignature=signature;send({type:'library',cards,complete:true});}
    if(reportedLoading){reportedLoading=false;send({type:'library-status',loading:false});}
  }catch{}}
  window.AnimeTvDashboard={snapshot};
  snapshot(true);setInterval(snapshot,3000);
})();
