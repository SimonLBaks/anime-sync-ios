(() => {
  if(window.AnimeTvFocus)return;
  const selector='a[href],button,input:not([type="hidden"]),textarea,select,summary,[tabindex],[role="tab"],[role="menuitem"],[role="menuitemcheckbox"],[role="menuitemradio"],[role="option"],[role="radio"],[role="checkbox"],[role="switch"],[role="slider"],[role="combobox"]';
  const interactive='a[href],button,input,textarea,select,summary,[role="tab"],[role="menuitem"],[role="menuitemcheckbox"],[role="menuitemradio"],[role="option"],[role="radio"],[role="checkbox"],[role="switch"],[role="slider"],[role="combobox"]';
  const keys={19:'ArrowUp',20:'ArrowDown',21:'ArrowLeft',22:'ArrowRight'};
  const keycodes={19:38,20:40,21:37,22:39};
  const openers=new WeakMap(),selectDialogs=new WeakMap();let previousFocus=null;
  const parent=el=>el?.parentElement||el?.getRootNode?.().host||null;
  const contains=(root,el)=>{if(root===document)return true;for(let n=el;n;n=parent(n))if(n===root)return true;return false;};
  function roots(scope=document){const out=[scope];for(let i=0;i<out.length&&i<20;i++)for(const el of out[i].querySelectorAll('*'))if(el.shadowRoot)out.push(el.shadowRoot);return out;}
  const all=(query,scope=document)=>roots(scope).flatMap(root=>[...root.querySelectorAll(query)]);
  function active(){let el=document.activeElement;for(let i=0;el?.shadowRoot?.activeElement&&i<20;i++)el=el.shadowRoot.activeElement;return el;}
  function visible(el){
    if(!el?.isConnected)return false;const r=el.getBoundingClientRect();if(r.width<=2||r.height<=2)return false;
    for(let n=el;n&&n.nodeType===1;n=parent(n)){
      if(n.hidden||n.inert||n.getAttribute('aria-hidden')==='true'||n.matches('aside[style*="site-rail"],dialog:not([open]),[role="dialog"][data-state="closed"],[role="alertdialog"][data-state="closed"],[role="menu"][data-state="closed"],[role="listbox"][data-state="closed"]'))return false;
      const style=getComputedStyle(n);if(style.visibility==='hidden'||style.visibility==='collapse'||style.display==='none'||Number(style.opacity)===0)return false;
    }return true;
  }
  function enabled(el){return visible(el)&&!el.matches(':disabled')&&!el.closest('[aria-disabled="true"]');}
  function scrollAxes(el){
    if(!el?.isConnected||el.matches('input,textarea,select'))return null;
    const style=getComputedStyle(el),root=el===document.scrollingElement;
    const x=el.clientWidth>2&&el.scrollWidth>el.clientWidth+4&&(root||/^(auto|scroll|overlay)$/.test(style.overflowX));
    const y=el.clientHeight>2&&el.scrollHeight>el.clientHeight+4&&(root||/^(auto|scroll|overlay)$/.test(style.overflowY));
    return x||y?{x,y}:null;
  }
  function candidates(scope){
    const controls=all(selector,scope).filter(el=>enabled(el)&&(el.matches(interactive)||el.tabIndex>=0));
    const regions=all('main,section,article,div,ul,ol,pre,[role="region"]',scope);
    if(scope.nodeType===1)regions.unshift(scope);
    const panes=regions.filter(el=>!controls.includes(el)&&enabled(el)&&scrollAxes(el)&&!controls.some(control=>contains(el,control)));
    return controls.concat(panes.filter(el=>!panes.some(child=>child!==el&&contains(el,child))));
  }
  function scrollStep(el,code,clamp){
    const axes=scrollAxes(el),vertical=code===19||code===20;if(!axes||!(vertical?axes.y:axes.x))return false;
    const before=vertical?el.scrollTop:el.scrollLeft,extent=vertical?el.clientHeight:el.clientWidth,max=vertical?el.scrollHeight-el.clientHeight:el.scrollWidth-el.clientWidth;
    const next=Math.max(0,Math.min(max,before+(code===19||code===21?-1:1)*Math.max(40,Math.round(extent*.7))));
    if(vertical)el.scrollTop=next;else el.scrollLeft=next;
    return next!==before||clamp&&vertical;
  }
  function scrollAncestor(el,code,inside){
    if(code!==19&&code!==20)return false;
    for(let at=parent(el);at;at=parent(at)){if(!contains(inside,at))break;if(scrollStep(at,code,false))return true;if(at===inside)break;}
    return inside===document&&scrollStep(document.scrollingElement,code,false);
  }
  function scope(){
    const expanded=all('[aria-expanded="true"][aria-controls]').map(el=>el.getAttribute('aria-controls'));
    const nodes=all('dialog[open],[role="dialog"],[role="alertdialog"],[aria-modal="true"],[role="menu"],[role="listbox"],[popover]').filter(el=>{
      if(!visible(el))return false;
      if(el.matches('dialog[open],[role="dialog"],[role="alertdialog"],[aria-modal="true"],[role="menu"]'))return true;
      if(el.hasAttribute('popover')){try{return el.matches(':popover-open');}catch{return false;}}
      return el.getAttribute('data-state')==='open'||!!el.id&&expanded.includes(el.id);
    });
    const rank=el=>{let z=0,topLayer=false;for(let n=el;n;n=parent(n)){try{if(n.matches(':modal,:popover-open'))topLayer=true;}catch{}const value=parseInt(getComputedStyle(n).zIndex,10);if(Number.isFinite(value))z=Math.max(z,value);}return (topLayer?1e12:0)+z;};
    return nodes.map((el,index)=>({el,index,z:rank(el)})).sort((a,b)=>a.z-b.z||a.index-b.index).at(-1)?.el||document;
  }
  function focus(el){
    if(!el||!enabled(el))return false;
    for(const old of all('[data-anime-tv-focus],[data-tv-focus]')){old.removeAttribute('data-anime-tv-focus');old.removeAttribute('data-tv-focus');}
    if(el.tabIndex<0&&!el.hasAttribute('tabindex'))el.setAttribute('tabindex','-1');
    el.setAttribute('data-anime-tv-focus','');el.focus({preventScroll:true});el.scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});return active()===el;
  }
  document.addEventListener('focusin',()=>{const current=active(),inside=scope();if(inside!==document&&previousFocus&&!contains(inside,previousFocus)&&enabled(previousFocus)&&!openers.has(inside))openers.set(inside,previousFocus);previousFocus=current;},true);
  function delegate(el,code){
    if(!el.closest('[role="tablist"],[role="menu"],[role="listbox"],[role="radiogroup"],[role="tree"],[role="slider"],[role="combobox"]'))return false;
    const before=active(),beforeScope=scope(),state=el.getAttribute('aria-valuenow')+'|'+el.getAttribute('aria-selected')+'|'+el.getAttribute('aria-expanded');
    const event=new KeyboardEvent('keydown',{key:keys[code],code:keys[code],keyCode:keycodes[code],which:keycodes[code],bubbles:true,cancelable:true,composed:true});
    Object.defineProperty(event,'animeTvNavigation',{value:true});el.dispatchEvent(event);
    return event.defaultPrevented||active()!==before||scope()!==beforeScope||state!==el.getAttribute('aria-valuenow')+'|'+el.getAttribute('aria-selected')+'|'+el.getAttribute('aria-expanded');
  }
  function edit(el,code){
    if(el.matches('input[type="range"]')&&(code===21||code===22)){
      const min=Number.isFinite(parseFloat(el.min))?Number(el.min):0,max=Number.isFinite(parseFloat(el.max))?Number(el.max):100,raw=Number(el.step),step=el.step==='any'?(max-min)/100:raw>0?raw:1;
      const value=Math.max(min,Math.min(max,Number(el.value)+(code===21?-step:step)));
      if(value!==Number(el.value)){Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,String(value));el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));}return true;
    }
    if(el.matches('input:not([type="range"]):not([type="checkbox"]):not([type="radio"]),textarea')&&(code===21||code===22)&&typeof el.selectionStart==='number'){
      const start=el.selectionStart,end=el.selectionEnd;
      if(code===21&&end>0){const at=start!==end?start:start-1;el.setSelectionRange(Math.max(0,at),Math.max(0,at));return true;}
      if(code===22&&start<el.value.length){const at=start!==end?end:end+1;el.setSelectionRange(at,at);return true;}
    }return false;
  }
  function logical(el,code,inside){
    const group=el.closest('nav,[role="tablist"],[role="menu"],[role="listbox"],[role="radiogroup"]');if(!group||!contains(inside,group))return false;
    const nav=group.matches('nav'),tabs=group.getAttribute('role')==='tablist';
    const nodes=candidates(group).filter(n=>n.closest('nav,[role="tablist"],[role="menu"],[role="listbox"],[role="radiogroup"]')===group);
    const boxes=nodes.map(n=>n.getBoundingClientRect()),spanX=boxes.length?Math.max(...boxes.map(r=>r.x))-Math.min(...boxes.map(r=>r.x)):0,spanY=boxes.length?Math.max(...boxes.map(r=>r.y))-Math.min(...boxes.map(r=>r.y)):0;
    const orientation=group.getAttribute('aria-orientation'),vertical=orientation==='vertical'||orientation!=='horizontal'&&(group.matches('[role="menu"],[role="listbox"]')||nav&&spanY>=spanX);
    if(nav&&vertical&&code===21&&inside!==document)return true;
    if(!((vertical&&(code===19||code===20))||(!vertical&&(code===21||code===22))))return false;
    const index=nodes.indexOf(el);if(index<0)return false;const next=index+(code===19||code===21?-1:1);
    if(next>=0&&next<nodes.length){focus(nodes[next]);return true;}return tabs||nav&&inside!==document;
  }
  function ranked(el,nodes,code,diagonal){
    const from=el.getBoundingClientRect(),x=(from.left+from.right)/2,y=(from.top+from.bottom)/2,horizontal=code===21||code===22;
    return nodes.filter(n=>n!==el&&!contains(n,el)).map(node=>{const r=node.getBoundingClientRect(),dx=(r.left+r.right)/2-x,dy=(r.top+r.bottom)/2-y;
      const forward=code===21?-dx:code===22?dx:code===19?-dy:dy,cross=horizontal?Math.abs(dy):Math.abs(dx);
      const beam=horizontal?Math.min(from.bottom,r.bottom)>Math.max(from.top,r.top):Math.min(from.right,r.right)>Math.max(from.left,r.left);
      return {node,forward,beam,score:forward+cross*3};}).filter(n=>n.forward>4&&(!horizontal||diagonal||n.beam)).sort((a,b)=>Number(b.beam)-Number(a.beam)||a.score-b.score)[0]?.node;
  }
  function ownerTab(el,nodes,code){
    const panel=el.closest('[role="tabpanel"]');if(!panel?.id)return null;
    const tab=nodes.find(n=>n.getAttribute('role')==='tab'&&(n.getAttribute('aria-controls')||'').split(/\s+/).includes(panel.id));if(!tab)return null;
    const from=el.getBoundingClientRect(),to=tab.getBoundingClientRect();
    if(code===21&&to.right<=from.left+4&&!ranked(el,nodes.filter(n=>contains(panel,n)),code,false))return tab;
    if(code===19&&to.bottom<=from.top+4&&!ranked(el,nodes.filter(n=>contains(panel,n)),code,false))return tab;
    return null;
  }
  function restore(el){if(!el)return;requestAnimationFrame(()=>{if(enabled(el))focus(el);});}
  function selectPicker(select){
    if(!select.options.length)return;
    const dialog=document.createElement('dialog');dialog.setAttribute('data-anime-tv-select','');dialog.setAttribute('aria-label',select.getAttribute('aria-label')||select.labels?.[0]?.textContent?.trim()||'Choose option');
    dialog.style.cssText='background:#181725;color:#eeeef0;border:1px solid #696175;border-radius:18px;padding:20px;width:min(560px,85vw);max-height:85vh;overflow:auto;font:inherit;';
    const title=document.createElement('h2');title.textContent=dialog.getAttribute('aria-label');title.style.cssText='margin:0 0 12px;font-size:22px';dialog.append(title);
    const list=document.createElement('div');list.setAttribute('role','listbox');dialog.append(list);const selected=new Set([...select.options].map((o,i)=>o.selected?i:-1).filter(i=>i>=0));
    const close=()=>{if(dialog.open)dialog.close();dialog.remove();restore(select);};selectDialogs.set(dialog,close);
    const commit=()=>{[...select.options].forEach((o,i)=>o.selected=selected.has(i));select.dispatchEvent(new Event('input',{bubbles:true}));select.dispatchEvent(new Event('change',{bubbles:true}));close();};
    const button=(label,action)=>{const el=document.createElement('button');el.type='button';el.textContent=label;el.style.cssText='position:relative;display:block;width:100%;min-height:44px;text-align:left;margin:5px 0;padding:10px 14px;color:inherit;background:#302b40;border:1px solid #5a516a;border-radius:10px;font:inherit;';el.addEventListener('click',action);return el;};
    let chosen=null;[...select.options].forEach((option,index)=>{const el=button(option.label,()=>{if(select.multiple){if(selected.has(index))selected.delete(index);else selected.add(index);el.setAttribute('aria-selected',String(selected.has(index)));}else{selected.clear();selected.add(index);commit();}});el.setAttribute('role','option');el.setAttribute('aria-selected',String(selected.has(index)));el.disabled=option.disabled||!!option.closest('optgroup[disabled]');if(option.selected&&!el.disabled)chosen=el;list.append(el);});
    if(select.multiple)dialog.append(button('Done',commit));dialog.append(button('Cancel',close));dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
    const inside=scope();(inside===document?document.body:inside).append(dialog);openers.set(dialog,select);dialog.showModal();focus(chosen||candidates(dialog)[0]);
  }
  function navigate(code,onSidebar){
    const inside=scope(),nodes=candidates(inside);let current=active();if(!nodes.includes(current))current=null;
    if(code===0){if(!current)focus(nodes.find(n=>{const r=n.getBoundingClientRect();return r.bottom>0&&r.top<innerHeight;})||nodes[0]);return;}
    if(code===23||code===66){
      if(!current){focus(nodes[0]);return;}
      if(current.tagName==='SELECT'){selectPicker(current);return;}
      if(!current.matches(interactive)&&scrollAxes(current))return;
      if(code===66&&current.tagName==='TEXTAREA'){const at=current.selectionStart,end=current.selectionEnd,value=current.value;Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(current,value.slice(0,at)+'\n'+value.slice(end));current.setSelectionRange(at+1,at+1);current.dispatchEvent(new Event('input',{bubbles:true}));return;}
      if(code===66&&current.tagName==='INPUT'&&['text','search','password','email','url','tel','number'].includes(current.type)&&current.form)current.form.requestSubmit();else current.click();return;
    }
    if(!keys[code])return;
    if(!current){focus(nodes.find(n=>{const r=n.getBoundingClientRect();return r.bottom>0&&r.top<innerHeight;})||nodes[0]);return;}
    if(edit(current,code)||delegate(current,code))return;
    if((!current.matches(interactive)&&scrollStep(current,code,true))||logical(current,code,inside))return;
    const next=ownerTab(current,nodes,code)||ranked(current,nodes,code,inside!==document);
    if(next)focus(next);else if(scrollAncestor(current,code,inside))return;else if(code===21&&inside===document)onSidebar?.();
  }
  function back(){
    const inside=scope();if(inside===document)return false;
    const close=selectDialogs.get(inside);if(close){close();return true;}
    const opener=openers.get(inside),target=contains(inside,active())?active():inside;
    const event=new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,which:27,bubbles:true,cancelable:true,composed:true});Object.defineProperty(event,'animeTvNavigation',{value:true});target.dispatchEvent(event);
    if(event.defaultPrevented||!visible(inside)||scope()!==inside){restore(opener);return true;}
    if(inside.hasAttribute('popover')&&typeof inside.hidePopover==='function'){inside.hidePopover();restore(opener);return true;}
    const dismiss=candidates(inside).find(el=>/^(close|dismiss|cancel|back)( (dialog|popup|menu|settings|window))?$/i.test((el.getAttribute('aria-label')||el.textContent||'').trim()));
    if(dismiss){dismiss.click();restore(opener);return true;}
    if(inside.tagName==='DIALOG'){inside.close();restore(opener);return true;}
    return false;
  }
  function text(value){const el=active();if(!el?.matches('input:not([type="file"]),textarea'))return;const prototype=el instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(prototype,'value')?.set?.call(el,value);el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));}
  const style=document.createElement('style');style.textContent='[data-anime-tv-focus]{outline:3px solid #eeeef0!important;outline-offset:3px;border-radius:8px}[data-anime-tv-select] button[aria-selected="true"]{border-color:#adebd6!important;background:#30443f!important}';document.head.append(style);
  window.AnimeTvFocus={navigate,back,text,isNavigationEvent:event=>event.animeTvNavigation===true};
})();
