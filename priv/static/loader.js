(()=>{var U=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],ae=["kind","to","href","patch","pop"];var de=e=>{if(typeof e=="string")return e.length>256?e.slice(0,256)+"\u2026":e;if(typeof e=="boolean"||typeof e=="number"&&Number.isFinite(e))return e},ce=(e,t)=>{let o=Object.getOwnPropertyDescriptor(e,t);return o&&"value"in o?o.value:void 0},$=(e,t,o)=>{let n={type:e,at:o};if(!t||typeof t!="object")return n;try{for(let d of ae){let a=de(ce(t,d));a!==void 0&&(n[d]=a)}}catch{}return n},j=e=>{let t=null,o=0,n=0;return{allow(d){let a=Math.floor(d/1e3);return a!==t&&(t=a,o=0),o<e?(o+=1,!0):(n+=1,!1)},dropped:()=>n}},H=(e,t)=>{let o=[],n=!1,d=0;return{push(a){n?t(a):o.length<e?o.push(a):d+=1},ready(){n=!0;let a=o;o=[],a.forEach(t)},dropped:()=>d}};var S=["bottom","top","left","right"],V="bottom";var W={edge:{min:120,ratio:.45,max:520},side:{min:280,ratio:.4,max:480}},y=e=>e==="left"||e==="right",q=e=>y(e)?W.side:W.edge,k=e=>q(e).min,T=(e,t)=>Math.max(k(t),e-48),A=(e,t)=>{let{ratio:o,max:n}=q(t);return Math.round(Math.min(e*o,n))},_=(e,t,o)=>{let n=Number.isFinite(e)?e:A(t,o);return Math.round(Math.min(Math.max(n,k(o)),T(t,o)))},B=(e,t,o,n,d)=>({bottom:d-o,top:o,left:t,right:n-t})[e],N=(e,t,o=!0)=>o?e==="open"?t:e==="collapsed"?34:0:0,J=e=>Number.isFinite(e)&&e>0,le=e=>Object.fromEntries(S.filter(t=>J(e[t])).map(t=>[t,e[t]])),X=()=>({dock:V,sizes:{},reserve:null}),pe=e=>typeof e=="boolean"?e:null,C=e=>{try{let t=JSON.parse(e);if(!t||typeof t!="object")return X();let o=S.includes(t.dock)?t.dock:V,n=pe(t.reserve);return t.sizes&&typeof t.sizes=="object"?{dock:o,sizes:le(t.sizes),reserve:n}:{dock:o,sizes:J(t.size)?{[o]:t.size}:{},reserve:n}}catch{return X()}},Q=({dock:e,sizes:t,reserve:o})=>JSON.stringify(typeof o=="boolean"?{dock:e,sizes:t,reserve:o}:{dock:e,sizes:t}),F=(e,t)=>typeof e.reserve=="boolean"?e.reserve:t!=="false";var te="pdt:state",oe="pdt:open",re="pdt:layout",me=["open","collapsed","hidden"],ge=16,he=64,xe={bottom:"ArrowUp",top:"ArrowDown",left:"ArrowRight",right:"ArrowLeft"},be={bottom:"ArrowDown",top:"ArrowUp",left:"ArrowLeft",right:"ArrowRight"},ye="pdt:",E=document.currentScript||document.querySelector("script[data-pdt-sid]"),we=()=>{try{let e=window.localStorage.getItem(te);return me.includes(e)?e:window.localStorage.getItem(oe)==="1"?"open":"collapsed"}catch{return"collapsed"}},Se=e=>{try{window.localStorage.setItem(te,e),window.localStorage.removeItem(oe)}catch{}},Ee=()=>{try{return C(window.localStorage.getItem(re))}catch{return C(null)}},ve=e=>{try{window.localStorage.setItem(re,Q(e))}catch{}},Le=`
  :host { all: initial; }
  .frame {
    position: fixed; z-index: 2147483000; border: 0; margin: 0; padding: 0;
    background: transparent; color-scheme: normal;
  }
  .frame.dock-bottom, .frame.dock-top {
    left: 0; right: 0; width: 100%; height: var(--pdt-extent);
    transition: height 120ms ease-out;
  }
  .frame.dock-bottom { bottom: 0; box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12); }
  .frame.dock-top { top: 0; box-shadow: 0 1px 0 rgba(0, 0, 0, .25), 0 4px 16px rgba(0, 0, 0, .12); }
  .frame.dock-left, .frame.dock-right {
    top: 0; bottom: 0; height: 100%; width: var(--pdt-extent);
    transition: width 120ms ease-out;
  }
  .frame.dock-left { left: 0; box-shadow: 1px 0 0 rgba(0, 0, 0, .25), 4px 0 16px rgba(0, 0, 0, .12); }
  .frame.dock-right { right: 0; box-shadow: -1px 0 0 rgba(0, 0, 0, .25), -4px 0 16px rgba(0, 0, 0, .12); }
  .frame.hidden { display: none; }
  .frame.dragging { pointer-events: none; transition: none; }
  .handle {
    position: fixed; z-index: 2147483001; display: none; touch-action: none; outline: none;
  }
  .handle.dock-bottom, .handle.dock-top { left: 0; right: 0; height: 12px; cursor: ns-resize; }
  .handle.dock-bottom { bottom: calc(var(--pdt-extent) - 6px); }
  .handle.dock-top { top: calc(var(--pdt-extent) - 6px); }
  .handle.dock-left, .handle.dock-right { top: 0; bottom: 0; width: 12px; cursor: ew-resize; }
  .handle.dock-left { left: calc(var(--pdt-extent) - 6px); }
  .handle.dock-right { right: calc(var(--pdt-extent) - 6px); }
  .handle::after {
    content: ""; position: absolute; left: 50%; top: 50%; width: 36px; height: 4px;
    transform: translate(-50%, -50%); border-radius: 2px; background: #fd4f00; opacity: 0;
    transition: opacity 120ms ease;
  }
  .handle.dock-left::after, .handle.dock-right::after { width: 4px; height: 36px; }
  .handle:hover::after, .handle:focus-visible::after, .handle.dragging::after { opacity: 1; }
  .handle.visible { display: block; }
  .pill {
    position: fixed; right: 12px; bottom: 12px; z-index: 2147483000;
    display: none; align-items: center; gap: 6px;
    height: 28px; padding: 0 12px; border: 0; border-radius: 14px;
    background: #1f2330; color: #fd4f00; cursor: pointer;
    font: 600 12px/28px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    box-shadow: 0 2px 10px rgba(0, 0, 0, .3);
    transition: transform 120ms ease;
  }
  .pill:hover { transform: translateY(-1px); }
  .pill:focus-visible { outline: 2px solid #fd4f00; outline-offset: 2px; }
  .pill.visible { display: inline-flex; }
  @media (prefers-reduced-motion: reduce) { .frame, .pill, .handle::after { transition: none; } }
`,ze=()=>{let e=document.documentElement,t=Object.fromEntries(["padding-left","padding-right"].map(n=>[n,{value:e.style.getPropertyValue(n),priority:e.style.getPropertyPriority(n)}])),o=n=>e.style.setProperty(n,t[n].value,t[n].priority);return(n,d)=>{["padding-left","padding-right"].forEach(a=>{if(o(a),a!==`padding-${n}`||d===0)return;let l=window.getComputedStyle(e).getPropertyValue(a)||"0px";e.style.setProperty(a,`calc(${l} + ${d}px)`,"important")})}},Z="phoenix-dev-toolbar",ee=()=>{let{pdtSid:e,pdtPath:t}=E.dataset;if(!e||!t||document.getElementById(Z))return;let o=document.createElement("div");o.id=Z,o.setAttribute("data-phx-update","ignore"),o.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let n=o.attachShadow({mode:"open"}),d=document.createElement("style");d.textContent=Le;let a=E.nonce||E.getAttribute("nonce");a&&d.setAttribute("nonce",a);let l=document.createElement("iframe");l.className="frame",l.title="Phoenix dev toolbar",l.src=`${t}/panel?sid=${encodeURIComponent(e)}`;let h=document.createElement("button");h.className="pill",h.type="button",h.textContent="dev toolbar",h.title="Show the dev toolbar";let s=document.createElement("div");s.className="handle",s.tabIndex=0,s.title="Drag to resize, double click to reset",s.setAttribute("role","separator"),s.setAttribute("aria-label","Resize the dev toolbar"),n.append(d,l,s,h);let m=we(),g=Ee(),M=E.dataset.pdtReserve,i=g.dock,ne=ze(),x=()=>y(i)?window.innerWidth:window.innerHeight,u=_(g.sizes[i],x(),i),v=(r,c={})=>l.contentWindow&&l.contentWindow.postMessage({type:ye+r,...c},window.location.origin),L=()=>v("state",{open:m==="open",dock:i,reserve:F(g,M)}),P=()=>ve({dock:i,sizes:g.sizes,reserve:g.reserve}),ie=()=>{i==="top"&&document.body.firstChild!==o&&document.body.prepend(o),i!=="top"&&document.body.lastChild!==o&&document.body.append(o)},z=()=>{let r=N(m,u,F(g,M));o.style.setProperty("--pdt-extent",`${m==="open"?u:N("collapsed",u)}px`),o.style.height=y(i)?"0":`${r}px`,ne(i,y(i)?r:0),s.setAttribute("aria-valuemin",String(k(i))),s.setAttribute("aria-valuemax",String(T(x(),i))),s.setAttribute("aria-valuenow",String(u)),s.setAttribute("aria-valuetext",`${u} pixels`)},w=(r,c)=>{u=_(r,x(),i),z(),c&&(g.sizes[i]=u,P())},Y=r=>{i=r,[l,s].forEach(c=>{S.forEach(f=>c.classList.toggle(`dock-${f}`,f===i))}),s.setAttribute("aria-orientation",y(i)?"vertical":"horizontal"),ie(),u=_(g.sizes[i],x(),i),z()},b=r=>{m=r,l.classList.toggle("hidden",m==="hidden"),s.classList.toggle("visible",m==="open"),h.classList.toggle("visible",m==="hidden"),z(),Se(m),L()},K=j(20),G=()=>K.dropped()+D.dropped(),D=H(50,r=>v("client",{event:r,dropped:G()})),I=null,se=()=>{I||(I=setTimeout(()=>{I=null,v("client",{event:null,dropped:G()})},1e3))};U.forEach(r=>window.addEventListener(r,c=>{try{let f=Date.now();K.allow(f)?D.push($(r,c.detail,f)):se()}catch{}},{passive:!0}));let p=null,R=()=>{p&&(p.frame&&cancelAnimationFrame(p.frame),p=null,l.classList.remove("dragging"),s.classList.remove("dragging"),w(u,!0))};s.addEventListener("pointerdown",r=>{r.button===0&&(r.preventDefault(),s.setPointerCapture(r.pointerId),p={frame:null,x:r.clientX,y:r.clientY},l.classList.add("dragging"),s.classList.add("dragging"))}),s.addEventListener("pointermove",r=>{p&&(p.x=r.clientX,p.y=r.clientY,!p.frame&&(p.frame=requestAnimationFrame(()=>{p&&(p.frame=null,w(B(i,p.x,p.y,window.innerWidth,window.innerHeight),!1))})))}),s.addEventListener("pointerup",R),s.addEventListener("pointercancel",R),s.addEventListener("lostpointercapture",R),s.addEventListener("dblclick",()=>w(A(x(),i),!0)),s.addEventListener("keydown",r=>{let c=r.shiftKey?he:ge,f={[xe[i]]:u+c,[be[i]]:u-c,Home:A(x(),i)}[r.key];f!==void 0&&(r.preventDefault(),w(f,!0))});let O=null;window.addEventListener("resize",()=>{O||(O=requestAnimationFrame(()=>{O=null,w(g.sizes[i],!1)}))},{passive:!0}),h.addEventListener("click",()=>{b("collapsed"),l.focus(),v("focus")}),l.addEventListener("load",()=>{L(),D.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==l.contentWindow)return;let c=r.data&&r.data.type;if(c==="pdt:toggle"&&b(m==="open"?"collapsed":"open"),c==="pdt:open"&&b("open"),c==="pdt:close"&&b("collapsed"),c==="pdt:hide"){let f=n.activeElement===l;b("hidden"),f&&h.focus()}c==="pdt:dock"&&S.includes(r.data.dock)&&(Y(r.data.dock),P(),L()),c==="pdt:reserve"&&typeof r.data.reserve=="boolean"&&(g.reserve=r.data.reserve,z(),P(),L())}),Y(i),b(m)};E&&window.top===window&&(document.body?ee():document.addEventListener("DOMContentLoaded",ee,{once:!0}));})();
