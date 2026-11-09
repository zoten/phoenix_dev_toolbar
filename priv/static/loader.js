(()=>{var F=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],rt=["kind","to","href","patch","pop"];var nt=t=>{if(typeof t=="string")return t.length>256?t.slice(0,256)+"\u2026":t;if(typeof t=="boolean"||typeof t=="number"&&Number.isFinite(t))return t},it=(t,e)=>{let o=Object.getOwnPropertyDescriptor(t,e);return o&&"value"in o?o.value:void 0},M=(t,e,o)=>{let i={type:t,at:o};if(!e||typeof e!="object")return i;try{for(let d of rt){let n=nt(it(e,d));n!==void 0&&(i[d]=n)}}catch{}return i},Y=t=>{let e=null,o=0,i=0;return{allow(d){let n=Math.floor(d/1e3);return n!==e&&(e=n,o=0),o<t?(o+=1,!0):(i+=1,!1)},dropped:()=>i}},K=(t,e)=>{let o=[],i=!1,d=0;return{push(n){i?e(n):o.length<t?o.push(n):d+=1},ready(){i=!0;let n=o;o=[],n.forEach(e)},dropped:()=>d}};var y=["bottom","top","left","right"],$="bottom";var G={edge:{min:120,ratio:.45,max:520},side:{min:280,ratio:.4,max:480}},b=t=>t==="left"||t==="right",j=t=>b(t)?G.side:G.edge,S=t=>j(t).min,I=(t,e)=>Math.max(S(e),t-48),E=(t,e)=>{let{ratio:o,max:i}=j(e);return Math.round(Math.min(t*o,i))},z=(t,e,o)=>{let i=Number.isFinite(t)?t:E(e,o);return Math.round(Math.min(Math.max(i,S(o)),I(e,o)))},W=(t,e,o,i,d)=>({bottom:d-o,top:o,left:e,right:i-e})[t],R=(t,e)=>t==="open"?e:t==="collapsed"?34:0,X=t=>Number.isFinite(t)&&t>0,at=t=>Object.fromEntries(y.filter(e=>X(t[e])).map(e=>[e,t[e]])),U=()=>({dock:$,sizes:{}}),T=t=>{try{let e=JSON.parse(t);if(!e||typeof e!="object")return U();let o=y.includes(e.dock)?e.dock:$;return e.sizes&&typeof e.sizes=="object"?{dock:o,sizes:at(e.sizes)}:{dock:o,sizes:X(e.size)?{[o]:e.size}:{}}}catch{return U()}},H=({dock:t,sizes:e})=>JSON.stringify({dock:t,sizes:e});var B="pdt:state",J="pdt:open",Q="pdt:layout",ct=["open","collapsed","hidden"],lt=16,pt=64,ut={bottom:"ArrowUp",top:"ArrowDown",left:"ArrowRight",right:"ArrowLeft"},ft={bottom:"ArrowDown",top:"ArrowUp",left:"ArrowLeft",right:"ArrowRight"},mt="pdt:",Z=document.currentScript||document.querySelector("script[data-pdt-sid]"),ht=()=>{try{let t=window.localStorage.getItem(B);return ct.includes(t)?t:window.localStorage.getItem(J)==="1"?"open":"collapsed"}catch{return"collapsed"}},gt=t=>{try{window.localStorage.setItem(B,t),window.localStorage.removeItem(J)}catch{}},xt=()=>{try{return T(window.localStorage.getItem(Q))}catch{return T(null)}},V=t=>{try{window.localStorage.setItem(Q,H(t))}catch{}},bt=`
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
`,wt=()=>{let t=document.documentElement,e=Object.fromEntries(["padding-left","padding-right"].map(i=>[i,{value:t.style.getPropertyValue(i),priority:t.style.getPropertyPriority(i)}])),o=i=>t.style.setProperty(i,e[i].value,e[i].priority);return(i,d)=>{["padding-left","padding-right"].forEach(n=>{if(o(n),n!==`padding-${i}`||d===0)return;let f=window.getComputedStyle(t).getPropertyValue(n)||"0px";t.style.setProperty(n,`calc(${f} + ${d}px)`,"important")})}},q=()=>{let{pdtSid:t,pdtPath:e}=Z.dataset;if(!t||!e)return;let o=document.createElement("div");o.id="phoenix-dev-toolbar",o.setAttribute("data-phx-update","ignore"),o.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let i=o.attachShadow({mode:"open"}),d=document.createElement("style");d.textContent=bt;let n=document.createElement("iframe");n.className="frame",n.title="Phoenix dev toolbar",n.src=`${e}/panel?sid=${encodeURIComponent(t)}`;let f=document.createElement("button");f.className="pill",f.type="button",f.textContent="dev toolbar",f.title="Show the dev toolbar";let s=document.createElement("div");s.className="handle",s.tabIndex=0,s.title="Drag to resize, double click to reset",s.setAttribute("role","separator"),s.setAttribute("aria-label","Resize the dev toolbar"),i.append(d,n,s,f);let p=ht(),h=xt(),a=h.dock,tt=wt(),g=()=>b(a)?window.innerWidth:window.innerHeight,u=z(h.sizes[a],g(),a),L=(r,c={})=>n.contentWindow&&n.contentWindow.postMessage({type:mt+r,...c},window.location.origin),v=()=>L("state",{open:p==="open",dock:a}),et=()=>{a==="top"&&document.body.firstChild!==o&&document.body.prepend(o),a!=="top"&&document.body.lastChild!==o&&document.body.append(o)},k=()=>{let r=R(p,u);o.style.setProperty("--pdt-extent",`${p==="open"?u:R("collapsed",u)}px`),o.style.height=b(a)?"0":`${r}px`,tt(a,b(a)?r:0),s.setAttribute("aria-valuemin",String(S(a))),s.setAttribute("aria-valuemax",String(I(g(),a))),s.setAttribute("aria-valuenow",String(u))},w=(r,c)=>{u=z(r,g(),a),k(),c&&(h.sizes[a]=u,V({dock:a,sizes:h.sizes}))},O=r=>{a=r,[n,s].forEach(c=>{y.forEach(m=>c.classList.toggle(`dock-${m}`,m===a))}),s.setAttribute("aria-orientation",b(a)?"vertical":"horizontal"),et(),u=z(h.sizes[a],g(),a),k()},x=r=>{p=r,n.classList.toggle("open",p==="open"),n.classList.toggle("hidden",p==="hidden"),s.classList.toggle("visible",p==="open"),f.classList.toggle("visible",p==="hidden"),k(),gt(p),v()},N=Y(20),C=()=>N.dropped()+A.dropped(),A=K(50,r=>L("client",{event:r,dropped:C()})),_=null,ot=()=>{_||(_=setTimeout(()=>{_=null,L("client",{event:null,dropped:C()})},1e3))};F.forEach(r=>window.addEventListener(r,c=>{try{let m=Date.now();N.allow(m)?A.push(M(r,c.detail,m)):ot()}catch{}},{passive:!0}));let l=null,P=()=>{l&&(l.frame&&cancelAnimationFrame(l.frame),l=null,n.classList.remove("dragging"),s.classList.remove("dragging"),w(u,!0))};s.addEventListener("pointerdown",r=>{r.button===0&&(r.preventDefault(),s.setPointerCapture(r.pointerId),l={frame:null,x:r.clientX,y:r.clientY},n.classList.add("dragging"),s.classList.add("dragging"))}),s.addEventListener("pointermove",r=>{l&&(l.x=r.clientX,l.y=r.clientY,!l.frame&&(l.frame=requestAnimationFrame(()=>{l&&(l.frame=null,w(W(a,l.x,l.y,window.innerWidth,window.innerHeight),!1))})))}),s.addEventListener("pointerup",P),s.addEventListener("pointercancel",P),s.addEventListener("lostpointercapture",P),s.addEventListener("dblclick",()=>w(E(g(),a),!0)),s.addEventListener("keydown",r=>{let c=r.shiftKey?pt:lt,m={[ut[a]]:u+c,[ft[a]]:u-c,Home:E(g(),a)}[r.key];m!==void 0&&(r.preventDefault(),w(m,!0))});let D=null;window.addEventListener("resize",()=>{D||(D=requestAnimationFrame(()=>{D=null,w(h.sizes[a],!1)}))},{passive:!0}),f.addEventListener("click",()=>x("collapsed")),n.addEventListener("load",()=>{v(),A.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==n.contentWindow)return;let c=r.data&&r.data.type;c==="pdt:toggle"&&x(p==="open"?"collapsed":"open"),c==="pdt:open"&&x("open"),c==="pdt:close"&&x("collapsed"),c==="pdt:hide"&&x("hidden"),c==="pdt:dock"&&y.includes(r.data.dock)&&(O(r.data.dock),V({dock:a,sizes:h.sizes}),v())}),O(a),x(p)};Z&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?q():document.addEventListener("DOMContentLoaded",q,{once:!0}));})();
