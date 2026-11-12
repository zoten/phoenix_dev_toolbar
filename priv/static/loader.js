(()=>{var U=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],se=["kind","to","href","patch","pop"];var de=e=>{if(typeof e=="string")return e.length>256?e.slice(0,256)+"\u2026":e;if(typeof e=="boolean"||typeof e=="number"&&Number.isFinite(e))return e},ce=(e,t)=>{let o=Object.getOwnPropertyDescriptor(e,t);return o&&"value"in o?o.value:void 0},$=(e,t,o)=>{let n={type:e,at:o};if(!t||typeof t!="object")return n;try{for(let d of se){let s=de(ce(t,d));s!==void 0&&(n[d]=s)}}catch{}return n},X=e=>{let t=null,o=0,n=0;return{allow(d){let s=Math.floor(d/1e3);return s!==t&&(t=s,o=0),o<e?(o+=1,!0):(n+=1,!1)},dropped:()=>n}},j=(e,t)=>{let o=[],n=!1,d=0;return{push(s){n?t(s):o.length<e?o.push(s):d+=1},ready(){n=!0;let s=o;o=[],s.forEach(t)},dropped:()=>d}};var S=["bottom","top","left","right"],V="bottom";var H={edge:{min:120,ratio:.45,max:520},side:{min:280,ratio:.4,max:480}},y=e=>e==="left"||e==="right",q=e=>y(e)?H.side:H.edge,z=e=>q(e).min,T=(e,t)=>Math.max(z(t),e-48),A=(e,t)=>{let{ratio:o,max:n}=q(t);return Math.round(Math.min(e*o,n))},_=(e,t,o)=>{let n=Number.isFinite(e)?e:A(t,o);return Math.round(Math.min(Math.max(n,z(o)),T(t,o)))},B=(e,t,o,n,d)=>({bottom:d-o,top:o,left:t,right:n-t})[e],N=(e,t,o=!0)=>o?e==="open"?t:e==="collapsed"?34:0:0,J=e=>Number.isFinite(e)&&e>0,le=e=>Object.fromEntries(S.filter(t=>J(e[t])).map(t=>[t,e[t]])),W=()=>({dock:V,sizes:{},reserve:null}),pe=e=>typeof e=="boolean"?e:null,C=e=>{try{let t=JSON.parse(e);if(!t||typeof t!="object")return W();let o=S.includes(t.dock)?t.dock:V,n=pe(t.reserve);return t.sizes&&typeof t.sizes=="object"?{dock:o,sizes:le(t.sizes),reserve:n}:{dock:o,sizes:J(t.size)?{[o]:t.size}:{},reserve:n}}catch{return W()}},Q=({dock:e,sizes:t,reserve:o})=>JSON.stringify(typeof o=="boolean"?{dock:e,sizes:t,reserve:o}:{dock:e,sizes:t}),F=(e,t)=>typeof e.reserve=="boolean"?e.reserve:t!=="false";var te="pdt:state",oe="pdt:open",re="pdt:layout",me=["open","collapsed","hidden"],he=16,ge=64,xe={bottom:"ArrowUp",top:"ArrowDown",left:"ArrowRight",right:"ArrowLeft"},be={bottom:"ArrowDown",top:"ArrowUp",left:"ArrowLeft",right:"ArrowRight"},ye="pdt:",E=document.currentScript||document.querySelector("script[data-pdt-sid]"),we=()=>{try{let e=window.localStorage.getItem(te);return me.includes(e)?e:window.localStorage.getItem(oe)==="1"?"open":"collapsed"}catch{return"collapsed"}},Se=e=>{try{window.localStorage.setItem(te,e),window.localStorage.removeItem(oe)}catch{}},Ee=()=>{try{return C(window.localStorage.getItem(re))}catch{return C(null)}},ve=e=>{try{window.localStorage.setItem(re,Q(e))}catch{}},Le=`
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
  .handle.dock-bottom { bottom: calc(var(--pdt-extent) - 2px); }
  .handle.dock-top { top: calc(var(--pdt-extent) - 2px); }
  .handle.dock-left, .handle.dock-right { top: 0; bottom: 0; width: 12px; cursor: ew-resize; }
  .handle.dock-left { left: calc(var(--pdt-extent) - 2px); }
  .handle.dock-right { right: calc(var(--pdt-extent) - 2px); }
  .handle::after {
    content: ""; position: absolute; left: 50%; top: 50%; width: 36px; height: 4px;
    transform: translate(-50%, -50%); border-radius: 2px; background: #fd4f00; opacity: 0;
    transition: opacity 120ms ease;
  }
  .handle.dock-bottom::after { top: auto; bottom: 0; transform: translateX(-50%); }
  .handle.dock-top::after { top: 0; transform: translateX(-50%); }
  .handle.dock-left::after, .handle.dock-right::after { width: 4px; height: 36px; }
  .handle.dock-left::after { left: 0; transform: translateY(-50%); }
  .handle.dock-right::after { left: auto; right: 0; transform: translateY(-50%); }
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
`,ke=()=>{let e=document.documentElement,t=Object.fromEntries(["padding-left","padding-right"].map(n=>[n,{value:e.style.getPropertyValue(n),priority:e.style.getPropertyPriority(n)}])),o=n=>e.style.setProperty(n,t[n].value,t[n].priority);return(n,d)=>{["padding-left","padding-right"].forEach(s=>{if(o(s),s!==`padding-${n}`||d===0)return;let l=window.getComputedStyle(e).getPropertyValue(s)||"0px";e.style.setProperty(s,`calc(${l} + ${d}px)`,"important")})}},Z="phoenix-dev-toolbar",ee=()=>{let{pdtSid:e,pdtPath:t}=E.dataset;if(!e||!t||document.getElementById(Z))return;let o=document.createElement("div");o.id=Z,o.setAttribute("data-phx-update","ignore"),o.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let n=o.attachShadow({mode:"open"}),d=document.createElement("style");d.textContent=Le;let s=E.nonce||E.getAttribute("nonce");s&&d.setAttribute("nonce",s);let l=document.createElement("iframe");l.className="frame",l.title="Phoenix dev toolbar",l.src=`${t}/panel?sid=${encodeURIComponent(e)}`;let g=document.createElement("button");g.className="pill",g.type="button",g.textContent="dev toolbar",g.title="Show the dev toolbar";let a=document.createElement("div");a.className="handle",a.tabIndex=0,a.title="Drag to resize, double click to reset",a.setAttribute("role","separator"),a.setAttribute("aria-label","Resize the dev toolbar"),n.append(d,l,a,g);let m=we(),h=Ee(),Y=E.dataset.pdtReserve,i=h.dock,ne=ke(),x=()=>y(i)?window.innerWidth:window.innerHeight,u=_(h.sizes[i],x(),i),v=(r,c={})=>l.contentWindow&&l.contentWindow.postMessage({type:ye+r,...c},window.location.origin),L=()=>v("state",{open:m==="open",dock:i,reserve:F(h,Y)}),P=()=>ve({dock:i,sizes:h.sizes,reserve:h.reserve}),ie=()=>{i==="top"&&document.body.firstChild!==o&&document.body.prepend(o),i!=="top"&&document.body.lastChild!==o&&document.body.append(o)},k=()=>{let r=N(m,u,F(h,Y));o.style.setProperty("--pdt-extent",`${m==="open"?u:N("collapsed",u)}px`),o.style.height=y(i)?"0":`${r}px`,ne(i,y(i)?r:0),a.setAttribute("aria-valuemin",String(z(i))),a.setAttribute("aria-valuemax",String(T(x(),i))),a.setAttribute("aria-valuenow",String(u)),a.setAttribute("aria-valuetext",`${u} pixels`)},w=(r,c)=>{u=_(r,x(),i),k(),c&&(h.sizes[i]=u,P())},M=r=>{i=r,[l,a].forEach(c=>{S.forEach(f=>c.classList.toggle(`dock-${f}`,f===i))}),a.setAttribute("aria-orientation",y(i)?"vertical":"horizontal"),ie(),u=_(h.sizes[i],x(),i),k()},b=r=>{m=r,l.classList.toggle("hidden",m==="hidden"),a.classList.toggle("visible",m==="open"),g.classList.toggle("visible",m==="hidden"),k(),Se(m),L()},K=X(20),G=()=>K.dropped()+D.dropped(),D=j(50,r=>v("client",{event:r,dropped:G()})),I=null,ae=()=>{I||(I=setTimeout(()=>{I=null,v("client",{event:null,dropped:G()})},1e3))};U.forEach(r=>window.addEventListener(r,c=>{try{let f=Date.now();K.allow(f)?D.push($(r,c.detail,f)):ae()}catch{}},{passive:!0}));let p=null,R=()=>{p&&(p.frame&&cancelAnimationFrame(p.frame),p=null,l.classList.remove("dragging"),a.classList.remove("dragging"),w(u,!0))};a.addEventListener("pointerdown",r=>{r.button===0&&(r.preventDefault(),a.setPointerCapture(r.pointerId),p={frame:null,x:r.clientX,y:r.clientY},l.classList.add("dragging"),a.classList.add("dragging"))}),a.addEventListener("pointermove",r=>{p&&(p.x=r.clientX,p.y=r.clientY,!p.frame&&(p.frame=requestAnimationFrame(()=>{p&&(p.frame=null,w(B(i,p.x,p.y,window.innerWidth,window.innerHeight),!1))})))}),a.addEventListener("pointerup",R),a.addEventListener("pointercancel",R),a.addEventListener("lostpointercapture",R),a.addEventListener("dblclick",()=>w(A(x(),i),!0)),a.addEventListener("keydown",r=>{let c=r.shiftKey?ge:he,f={[xe[i]]:u+c,[be[i]]:u-c,Home:A(x(),i)}[r.key];f!==void 0&&(r.preventDefault(),w(f,!0))});let O=null;window.addEventListener("resize",()=>{O||(O=requestAnimationFrame(()=>{O=null,w(h.sizes[i],!1)}))},{passive:!0}),g.addEventListener("click",()=>{b("collapsed"),l.focus(),v("focus")}),l.addEventListener("load",()=>{L(),D.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==l.contentWindow)return;let c=r.data&&r.data.type;if(c==="pdt:toggle"&&b(m==="open"?"collapsed":"open"),c==="pdt:open"&&b("open"),c==="pdt:close"&&b("collapsed"),c==="pdt:hide"){let f=n.activeElement===l;b("hidden"),f&&g.focus()}c==="pdt:dock"&&S.includes(r.data.dock)&&(M(r.data.dock),P(),L()),c==="pdt:reserve"&&typeof r.data.reserve=="boolean"&&(h.reserve=r.data.reserve,k(),P(),L())}),M(i),b(m)};E&&window.top===window&&(document.body?ee():document.addEventListener("DOMContentLoaded",ee,{once:!0}));})();
