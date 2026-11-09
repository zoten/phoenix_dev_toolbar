(()=>{var D=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],X=["kind","to","href","patch","pop"];var $=e=>{if(typeof e=="string")return e.length>256?e.slice(0,256)+"\u2026":e;if(typeof e=="boolean"||typeof e=="number"&&Number.isFinite(e))return e},q=(e,o)=>{let t=Object.getOwnPropertyDescriptor(e,o);return t&&"value"in t?t.value:void 0},M=(e,o,t)=>{let a={type:e,at:t};if(!o||typeof o!="object")return a;try{for(let l of X){let r=$(q(o,l));r!==void 0&&(a[l]=r)}}catch{}return a},N=e=>{let o=null,t=0,a=0;return{allow(l){let r=Math.floor(l/1e3);return r!==o&&(o=r,t=0),t<e?(t+=1,!0):(a+=1,!1)},dropped:()=>a}},P=(e,o)=>{let t=[],a=!1,l=0;return{push(r){a?o(r):t.length<e?t.push(r):l+=1},ready(){a=!0;let r=t;t=[],r.forEach(o)},dropped:()=>l}};var V=["bottom"],E=e=>Math.round(Math.min(e*.45,520)),v=(e,o)=>{let t=Math.max(120,o-48),a=Number.isFinite(e)?e:E(o);return Math.round(Math.min(Math.max(a,120),t))},F=(e,o)=>e==="open"?o:e==="collapsed"?34:0,R={dock:"bottom",size:null},_=e=>{try{let{dock:o,size:t}=JSON.parse(e);return V.includes(o)?{dock:o,size:Number.isFinite(t)&&t>0?t:null}:{...R}}catch{return{...R}}},k=({dock:e,size:o})=>JSON.stringify({dock:e,size:o});var Y="pdt:state",G="pdt:open",U="pdt:layout",J=["open","collapsed","hidden"],Q=16,ee=64,te="pdt:",K=document.currentScript||document.querySelector("script[data-pdt-sid]"),oe=()=>{try{let e=window.localStorage.getItem(Y);return J.includes(e)?e:window.localStorage.getItem(G)==="1"?"open":"collapsed"}catch{return"collapsed"}},ne=e=>{try{window.localStorage.setItem(Y,e),window.localStorage.removeItem(G)}catch{}},re=()=>{try{return _(window.localStorage.getItem(U))}catch{return _(null)}},ie=e=>{try{window.localStorage.setItem(U,k(e))}catch{}},ae=`
  :host { all: initial; }
  .frame {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;
    width: 100%; height: ${34}px; border: 0; margin: 0; padding: 0;
    box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12);
    background: transparent; color-scheme: normal;
    transition: height 120ms ease-out;
  }
  .frame.open { height: var(--pdt-size); }
  .frame.hidden { display: none; }
  .frame.dragging { pointer-events: none; transition: none; }
  .handle {
    position: fixed; left: 0; right: 0; bottom: calc(var(--pdt-size) - 3px);
    z-index: 2147483001; height: 6px; display: none;
    cursor: ns-resize; touch-action: none; outline: none;
  }
  .handle::after {
    content: ""; position: absolute; left: 50%; top: 1px; width: 36px; height: 4px;
    margin-left: -18px; border-radius: 2px; background: #fd4f00; opacity: 0;
    transition: opacity 120ms ease;
  }
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
`,C=()=>{let{pdtSid:e,pdtPath:o}=K.dataset;if(!e||!o)return;let t=document.createElement("div");t.id="phoenix-dev-toolbar",t.setAttribute("data-phx-update","ignore"),t.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let a=t.attachShadow({mode:"open"}),l=document.createElement("style");l.textContent=ae;let r=document.createElement("iframe");r.className="frame",r.title="Phoenix dev toolbar",r.src=`${o}/panel?sid=${encodeURIComponent(e)}`;let u=document.createElement("button");u.className="pill",u.type="button",u.textContent="dev toolbar",u.title="Show the dev toolbar";let i=document.createElement("div");i.className="handle",i.tabIndex=0,i.title="Drag to resize, double click to reset",i.setAttribute("role","separator"),i.setAttribute("aria-orientation","horizontal"),i.setAttribute("aria-label","Resize the dev toolbar"),a.append(l,r,i,u),document.body.appendChild(t);let p=oe(),A=re(),f=()=>window.innerHeight,b=A.size,c=v(b,f()),x=(n,s={})=>r.contentWindow&&r.contentWindow.postMessage({type:te+n,...s},window.location.origin),I=()=>{t.style.setProperty("--pdt-size",`${c}px`),t.style.height=`${F(p,c)}px`,i.setAttribute("aria-valuemin",String(120)),i.setAttribute("aria-valuemax",String(Math.max(120,f()-48))),i.setAttribute("aria-valuenow",String(c))},g=(n,s)=>{c=v(n,f()),I(),s&&(b=c,ie({dock:A.dock,size:c}))},m=n=>{p=n,r.classList.toggle("open",p==="open"),r.classList.toggle("hidden",p==="hidden"),i.classList.toggle("visible",p==="open"),u.classList.toggle("visible",p==="hidden"),I(),ne(p),x("state",{open:p==="open"})},z=N(20),T=()=>z.dropped()+w.dropped(),w=P(50,n=>x("client",{event:n,dropped:T()})),S=null,Z=()=>{S||(S=setTimeout(()=>{S=null,x("client",{event:null,dropped:T()})},1e3))};D.forEach(n=>window.addEventListener(n,s=>{try{let h=Date.now();z.allow(h)?w.push(M(n,s.detail,h)):Z()}catch{}},{passive:!0}));let d=null,y=()=>{d&&(d.frame&&cancelAnimationFrame(d.frame),d=null,r.classList.remove("dragging"),i.classList.remove("dragging"),g(c,!0))};i.addEventListener("pointerdown",n=>{n.button===0&&(n.preventDefault(),i.setPointerCapture(n.pointerId),d={frame:null,y:n.clientY},r.classList.add("dragging"),i.classList.add("dragging"))}),i.addEventListener("pointermove",n=>{d&&(d.y=n.clientY,!d.frame&&(d.frame=requestAnimationFrame(()=>{d&&(d.frame=null,g(f()-d.y,!1))})))}),i.addEventListener("pointerup",y),i.addEventListener("pointercancel",y),i.addEventListener("lostpointercapture",y),i.addEventListener("dblclick",()=>g(E(f()),!0)),i.addEventListener("keydown",n=>{let s=n.shiftKey?ee:Q,h={ArrowUp:c+s,ArrowDown:c-s,Home:E(f())}[n.key];h!==void 0&&(n.preventDefault(),g(h,!0))});let L=null;window.addEventListener("resize",()=>{L||(L=requestAnimationFrame(()=>{L=null,g(b,!1)}))},{passive:!0}),u.addEventListener("click",()=>m("collapsed")),r.addEventListener("load",()=>{x("state",{open:p==="open"}),w.ready()}),window.addEventListener("message",n=>{if(n.origin!==window.location.origin||n.source!==r.contentWindow)return;let s=n.data&&n.data.type;s==="pdt:toggle"&&m(p==="open"?"collapsed":"open"),s==="pdt:open"&&m("open"),s==="pdt:close"&&m("collapsed"),s==="pdt:hide"&&m("hidden")}),m(p)};K&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?C():document.addEventListener("DOMContentLoaded",C,{once:!0}));})();
