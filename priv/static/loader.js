(()=>{var G=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],ie=["kind","to","href","patch","pop"];var ae=e=>{if(typeof e=="string")return e.length>256?e.slice(0,256)+"\u2026":e;if(typeof e=="boolean"||typeof e=="number"&&Number.isFinite(e))return e},se=(e,t)=>{let o=Object.getOwnPropertyDescriptor(e,t);return o&&"value"in o?o.value:void 0},U=(e,t,o)=>{let n={type:e,at:o};if(!t||typeof t!="object")return n;try{for(let c of ie){let i=ae(se(t,c));i!==void 0&&(n[c]=i)}}catch{}return n},$=e=>{let t=null,o=0,n=0;return{allow(c){let i=Math.floor(c/1e3);return i!==t&&(t=i,o=0),o<e?(o+=1,!0):(n+=1,!1)},dropped:()=>n}},j=(e,t)=>{let o=[],n=!1,c=0;return{push(i){n?t(i):o.length<e?o.push(i):c+=1},ready(){n=!0;let i=o;o=[],i.forEach(t)},dropped:()=>c}};var y=["bottom","top","left","right"],H="bottom";var W={edge:{min:120,ratio:.45,max:520},side:{min:280,ratio:.4,max:480}},b=e=>e==="left"||e==="right",V=e=>b(e)?W.side:W.edge,v=e=>V(e).min,I=(e,t)=>Math.max(v(t),e-48),L=(e,t)=>{let{ratio:o,max:n}=V(t);return Math.round(Math.min(e*o,n))},z=(e,t,o)=>{let n=Number.isFinite(e)?e:L(t,o);return Math.round(Math.min(Math.max(n,v(o)),I(t,o)))},q=(e,t,o,n,c)=>({bottom:c-o,top:o,left:t,right:n-t})[e],T=(e,t,o=!0)=>o?e==="open"?t:e==="collapsed"?34:0:0,B=e=>Number.isFinite(e)&&e>0,de=e=>Object.fromEntries(y.filter(t=>B(e[t])).map(t=>[t,e[t]])),X=()=>({dock:H,sizes:{},reserve:null}),ce=e=>typeof e=="boolean"?e:null,O=e=>{try{let t=JSON.parse(e);if(!t||typeof t!="object")return X();let o=y.includes(t.dock)?t.dock:H,n=ce(t.reserve);return t.sizes&&typeof t.sizes=="object"?{dock:o,sizes:de(t.sizes),reserve:n}:{dock:o,sizes:B(t.size)?{[o]:t.size}:{},reserve:n}}catch{return X()}},J=({dock:e,sizes:t,reserve:o})=>JSON.stringify(typeof o=="boolean"?{dock:e,sizes:t,reserve:o}:{dock:e,sizes:t}),N=(e,t)=>typeof e.reserve=="boolean"?e.reserve:t!=="false";var Z="pdt:state",ee="pdt:open",te="pdt:layout",ue=["open","collapsed","hidden"],fe=16,me=64,he={bottom:"ArrowUp",top:"ArrowDown",left:"ArrowRight",right:"ArrowLeft"},ge={bottom:"ArrowDown",top:"ArrowUp",left:"ArrowLeft",right:"ArrowRight"},xe="pdt:",C=document.currentScript||document.querySelector("script[data-pdt-sid]"),be=()=>{try{let e=window.localStorage.getItem(Z);return ue.includes(e)?e:window.localStorage.getItem(ee)==="1"?"open":"collapsed"}catch{return"collapsed"}},we=e=>{try{window.localStorage.setItem(Z,e),window.localStorage.removeItem(ee)}catch{}},ye=()=>{try{return O(window.localStorage.getItem(te))}catch{return O(null)}},Se=e=>{try{window.localStorage.setItem(te,J(e))}catch{}},Ee=`
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
  .handle.dock-bottom, .handle.dock-top { left: 0; right: 0; height: 6px; cursor: ns-resize; }
  .handle.dock-bottom { bottom: calc(var(--pdt-extent) - 3px); }
  .handle.dock-top { top: calc(var(--pdt-extent) - 3px); }
  .handle.dock-left, .handle.dock-right { top: 0; bottom: 0; width: 6px; cursor: ew-resize; }
  .handle.dock-left { left: calc(var(--pdt-extent) - 3px); }
  .handle.dock-right { right: calc(var(--pdt-extent) - 3px); }
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
`,ve=()=>{let e=document.documentElement,t=Object.fromEntries(["padding-left","padding-right"].map(n=>[n,{value:e.style.getPropertyValue(n),priority:e.style.getPropertyPriority(n)}])),o=n=>e.style.setProperty(n,t[n].value,t[n].priority);return(n,c)=>{["padding-left","padding-right"].forEach(i=>{if(o(i),i!==`padding-${n}`||c===0)return;let m=window.getComputedStyle(e).getPropertyValue(i)||"0px";e.style.setProperty(i,`calc(${m} + ${c}px)`,"important")})}},Q=()=>{let{pdtSid:e,pdtPath:t}=C.dataset;if(!e||!t)return;let o=document.createElement("div");o.id="phoenix-dev-toolbar",o.setAttribute("data-phx-update","ignore"),o.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let n=o.attachShadow({mode:"open"}),c=document.createElement("style");c.textContent=Ee;let i=document.createElement("iframe");i.className="frame",i.title="Phoenix dev toolbar",i.src=`${t}/panel?sid=${encodeURIComponent(e)}`;let m=document.createElement("button");m.className="pill",m.type="button",m.textContent="dev toolbar",m.title="Show the dev toolbar";let s=document.createElement("div");s.className="handle",s.tabIndex=0,s.title="Drag to resize, double click to reset",s.setAttribute("role","separator"),s.setAttribute("aria-label","Resize the dev toolbar"),n.append(c,i,s,m);let p=be(),u=ye(),F=C.dataset.pdtReserve,a=u.dock,oe=ve(),g=()=>b(a)?window.innerWidth:window.innerHeight,f=z(u.sizes[a],g(),a),k=(r,d={})=>i.contentWindow&&i.contentWindow.postMessage({type:xe+r,...d},window.location.origin),S=()=>k("state",{open:p==="open",dock:a,reserve:N(u,F)}),A=()=>Se({dock:a,sizes:u.sizes,reserve:u.reserve}),re=()=>{a==="top"&&document.body.firstChild!==o&&document.body.prepend(o),a!=="top"&&document.body.lastChild!==o&&document.body.append(o)},E=()=>{let r=T(p,f,N(u,F));o.style.setProperty("--pdt-extent",`${p==="open"?f:T("collapsed",f)}px`),o.style.height=b(a)?"0":`${r}px`,oe(a,b(a)?r:0),s.setAttribute("aria-valuemin",String(v(a))),s.setAttribute("aria-valuemax",String(I(g(),a))),s.setAttribute("aria-valuenow",String(f))},w=(r,d)=>{f=z(r,g(),a),E(),d&&(u.sizes[a]=f,A())},M=r=>{a=r,[i,s].forEach(d=>{y.forEach(h=>d.classList.toggle(`dock-${h}`,h===a))}),s.setAttribute("aria-orientation",b(a)?"vertical":"horizontal"),re(),f=z(u.sizes[a],g(),a),E()},x=r=>{p=r,i.classList.toggle("hidden",p==="hidden"),s.classList.toggle("visible",p==="open"),m.classList.toggle("visible",p==="hidden"),E(),we(p),S()},Y=$(20),K=()=>Y.dropped()+_.dropped(),_=j(50,r=>k("client",{event:r,dropped:K()})),D=null,ne=()=>{D||(D=setTimeout(()=>{D=null,k("client",{event:null,dropped:K()})},1e3))};G.forEach(r=>window.addEventListener(r,d=>{try{let h=Date.now();Y.allow(h)?_.push(U(r,d.detail,h)):ne()}catch{}},{passive:!0}));let l=null,P=()=>{l&&(l.frame&&cancelAnimationFrame(l.frame),l=null,i.classList.remove("dragging"),s.classList.remove("dragging"),w(f,!0))};s.addEventListener("pointerdown",r=>{r.button===0&&(r.preventDefault(),s.setPointerCapture(r.pointerId),l={frame:null,x:r.clientX,y:r.clientY},i.classList.add("dragging"),s.classList.add("dragging"))}),s.addEventListener("pointermove",r=>{l&&(l.x=r.clientX,l.y=r.clientY,!l.frame&&(l.frame=requestAnimationFrame(()=>{l&&(l.frame=null,w(q(a,l.x,l.y,window.innerWidth,window.innerHeight),!1))})))}),s.addEventListener("pointerup",P),s.addEventListener("pointercancel",P),s.addEventListener("lostpointercapture",P),s.addEventListener("dblclick",()=>w(L(g(),a),!0)),s.addEventListener("keydown",r=>{let d=r.shiftKey?me:fe,h={[he[a]]:f+d,[ge[a]]:f-d,Home:L(g(),a)}[r.key];h!==void 0&&(r.preventDefault(),w(h,!0))});let R=null;window.addEventListener("resize",()=>{R||(R=requestAnimationFrame(()=>{R=null,w(u.sizes[a],!1)}))},{passive:!0}),m.addEventListener("click",()=>x("collapsed")),i.addEventListener("load",()=>{S(),_.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==i.contentWindow)return;let d=r.data&&r.data.type;d==="pdt:toggle"&&x(p==="open"?"collapsed":"open"),d==="pdt:open"&&x("open"),d==="pdt:close"&&x("collapsed"),d==="pdt:hide"&&x("hidden"),d==="pdt:dock"&&y.includes(r.data.dock)&&(M(r.data.dock),A(),S()),d==="pdt:reserve"&&typeof r.data.reserve=="boolean"&&(u.reserve=r.data.reserve,E(),A(),S())}),M(a),x(p)};C&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?Q():document.addEventListener("DOMContentLoaded",Q,{once:!0}));})();
