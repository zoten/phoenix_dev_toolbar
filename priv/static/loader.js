(()=>{var U=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],ae=["kind","to","href","patch","pop"];var se=e=>{if(typeof e=="string")return e.length>256?e.slice(0,256)+"\u2026":e;if(typeof e=="boolean"||typeof e=="number"&&Number.isFinite(e))return e},de=(e,t)=>{let o=Object.getOwnPropertyDescriptor(e,t);return o&&"value"in o?o.value:void 0},$=(e,t,o)=>{let n={type:e,at:o};if(!t||typeof t!="object")return n;try{for(let d of ae){let s=se(de(t,d));s!==void 0&&(n[d]=s)}}catch{}return n},j=e=>{let t=null,o=0,n=0;return{allow(d){let s=Math.floor(d/1e3);return s!==t&&(t=s,o=0),o<e?(o+=1,!0):(n+=1,!1)},dropped:()=>n}},W=(e,t)=>{let o=[],n=!1,d=0;return{push(s){n?t(s):o.length<e?o.push(s):d+=1},ready(){n=!0;let s=o;o=[],s.forEach(t)},dropped:()=>d}};var S=["bottom","top","left","right"],V="bottom";var X={edge:{min:120,ratio:.45,max:520},side:{min:280,ratio:.4,max:480}},w=e=>e==="left"||e==="right",q=e=>w(e)?X.side:X.edge,z=e=>q(e).min,O=(e,t)=>Math.max(z(t),e-48),k=(e,t)=>{let{ratio:o,max:n}=q(t);return Math.round(Math.min(e*o,n))},A=(e,t,o)=>{let n=Number.isFinite(e)?e:k(t,o);return Math.round(Math.min(Math.max(n,z(o)),O(t,o)))},B=(e,t,o,n,d)=>({bottom:d-o,top:o,left:t,right:n-t})[e],N=(e,t,o=!0)=>o?e==="open"?t:e==="collapsed"?34:0:0,J=e=>Number.isFinite(e)&&e>0,ce=e=>Object.fromEntries(S.filter(t=>J(e[t])).map(t=>[t,e[t]])),H=()=>({dock:V,sizes:{},reserve:null}),le=e=>typeof e=="boolean"?e:null,C=e=>{try{let t=JSON.parse(e);if(!t||typeof t!="object")return H();let o=S.includes(t.dock)?t.dock:V,n=le(t.reserve);return t.sizes&&typeof t.sizes=="object"?{dock:o,sizes:ce(t.sizes),reserve:n}:{dock:o,sizes:J(t.size)?{[o]:t.size}:{},reserve:n}}catch{return H()}},Q=({dock:e,sizes:t,reserve:o})=>JSON.stringify(typeof o=="boolean"?{dock:e,sizes:t,reserve:o}:{dock:e,sizes:t}),F=(e,t)=>typeof e.reserve=="boolean"?e.reserve:t!=="false";var ee="pdt:state",te="pdt:open",oe="pdt:layout",fe=["open","collapsed","hidden"],me=16,he=64,ge={bottom:"ArrowUp",top:"ArrowDown",left:"ArrowRight",right:"ArrowLeft"},xe={bottom:"ArrowDown",top:"ArrowUp",left:"ArrowLeft",right:"ArrowRight"},be="pdt:",E=document.currentScript||document.querySelector("script[data-pdt-sid]"),we=()=>{try{let e=window.localStorage.getItem(ee);return fe.includes(e)?e:window.localStorage.getItem(te)==="1"?"open":"collapsed"}catch{return"collapsed"}},ye=e=>{try{window.localStorage.setItem(ee,e),window.localStorage.removeItem(te)}catch{}},Se=()=>{try{return C(window.localStorage.getItem(oe))}catch{return C(null)}},Ee=e=>{try{window.localStorage.setItem(oe,Q(e))}catch{}},ve=`
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
`,Le=()=>{let e=document.documentElement,t=Object.fromEntries(["padding-left","padding-right"].map(n=>[n,{value:e.style.getPropertyValue(n),priority:e.style.getPropertyPriority(n)}])),o=n=>e.style.setProperty(n,t[n].value,t[n].priority);return(n,d)=>{["padding-left","padding-right"].forEach(s=>{if(o(s),s!==`padding-${n}`||d===0)return;let l=window.getComputedStyle(e).getPropertyValue(s)||"0px";e.style.setProperty(s,`calc(${l} + ${d}px)`,"important")})}},Z=()=>{let{pdtSid:e,pdtPath:t}=E.dataset;if(!e||!t)return;let o=document.createElement("div");o.id="phoenix-dev-toolbar",o.setAttribute("data-phx-update","ignore"),o.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let n=o.attachShadow({mode:"open"}),d=document.createElement("style");d.textContent=ve;let s=E.nonce||E.getAttribute("nonce");s&&d.setAttribute("nonce",s);let l=document.createElement("iframe");l.className="frame",l.title="Phoenix dev toolbar",l.src=`${t}/panel?sid=${encodeURIComponent(e)}`;let g=document.createElement("button");g.className="pill",g.type="button",g.textContent="dev toolbar",g.title="Show the dev toolbar";let a=document.createElement("div");a.className="handle",a.tabIndex=0,a.title="Drag to resize, double click to reset",a.setAttribute("role","separator"),a.setAttribute("aria-label","Resize the dev toolbar"),n.append(d,l,a,g);let u=we(),f=Se(),M=E.dataset.pdtReserve,i=f.dock,re=Le(),x=()=>w(i)?window.innerWidth:window.innerHeight,m=A(f.sizes[i],x(),i),_=(r,c={})=>l.contentWindow&&l.contentWindow.postMessage({type:be+r,...c},window.location.origin),v=()=>_("state",{open:u==="open",dock:i,reserve:F(f,M)}),D=()=>Ee({dock:i,sizes:f.sizes,reserve:f.reserve}),ne=()=>{i==="top"&&document.body.firstChild!==o&&document.body.prepend(o),i!=="top"&&document.body.lastChild!==o&&document.body.append(o)},L=()=>{let r=N(u,m,F(f,M));o.style.setProperty("--pdt-extent",`${u==="open"?m:N("collapsed",m)}px`),o.style.height=w(i)?"0":`${r}px`,re(i,w(i)?r:0),a.setAttribute("aria-valuemin",String(z(i))),a.setAttribute("aria-valuemax",String(O(x(),i))),a.setAttribute("aria-valuenow",String(m))},y=(r,c)=>{m=A(r,x(),i),L(),c&&(f.sizes[i]=m,D())},Y=r=>{i=r,[l,a].forEach(c=>{S.forEach(h=>c.classList.toggle(`dock-${h}`,h===i))}),a.setAttribute("aria-orientation",w(i)?"vertical":"horizontal"),ne(),m=A(f.sizes[i],x(),i),L()},b=r=>{u=r,l.classList.toggle("hidden",u==="hidden"),a.classList.toggle("visible",u==="open"),g.classList.toggle("visible",u==="hidden"),L(),ye(u),v()},K=j(20),G=()=>K.dropped()+P.dropped(),P=W(50,r=>_("client",{event:r,dropped:G()})),R=null,ie=()=>{R||(R=setTimeout(()=>{R=null,_("client",{event:null,dropped:G()})},1e3))};U.forEach(r=>window.addEventListener(r,c=>{try{let h=Date.now();K.allow(h)?P.push($(r,c.detail,h)):ie()}catch{}},{passive:!0}));let p=null,I=()=>{p&&(p.frame&&cancelAnimationFrame(p.frame),p=null,l.classList.remove("dragging"),a.classList.remove("dragging"),y(m,!0))};a.addEventListener("pointerdown",r=>{r.button===0&&(r.preventDefault(),a.setPointerCapture(r.pointerId),p={frame:null,x:r.clientX,y:r.clientY},l.classList.add("dragging"),a.classList.add("dragging"))}),a.addEventListener("pointermove",r=>{p&&(p.x=r.clientX,p.y=r.clientY,!p.frame&&(p.frame=requestAnimationFrame(()=>{p&&(p.frame=null,y(B(i,p.x,p.y,window.innerWidth,window.innerHeight),!1))})))}),a.addEventListener("pointerup",I),a.addEventListener("pointercancel",I),a.addEventListener("lostpointercapture",I),a.addEventListener("dblclick",()=>y(k(x(),i),!0)),a.addEventListener("keydown",r=>{let c=r.shiftKey?he:me,h={[ge[i]]:m+c,[xe[i]]:m-c,Home:k(x(),i)}[r.key];h!==void 0&&(r.preventDefault(),y(h,!0))});let T=null;window.addEventListener("resize",()=>{T||(T=requestAnimationFrame(()=>{T=null,y(f.sizes[i],!1)}))},{passive:!0}),g.addEventListener("click",()=>b("collapsed")),l.addEventListener("load",()=>{v(),P.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==l.contentWindow)return;let c=r.data&&r.data.type;c==="pdt:toggle"&&b(u==="open"?"collapsed":"open"),c==="pdt:open"&&b("open"),c==="pdt:close"&&b("collapsed"),c==="pdt:hide"&&b("hidden"),c==="pdt:dock"&&S.includes(r.data.dock)&&(Y(r.data.dock),D(),v()),c==="pdt:reserve"&&typeof r.data.reserve=="boolean"&&(f.reserve=r.data.reserve,L(),D(),v())}),Y(i),b(u)};E&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?Z():document.addEventListener("DOMContentLoaded",Z,{once:!0}));})();
