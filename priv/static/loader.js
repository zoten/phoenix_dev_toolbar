(()=>{var H=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],mt=["kind","to","href","patch","pop"];var ht=t=>{if(typeof t=="string")return t.length>256?t.slice(0,256)+"\u2026":t;if(typeof t=="boolean"||typeof t=="number"&&Number.isFinite(t))return t},gt=(t,e)=>{let o=Object.getOwnPropertyDescriptor(t,e);return o&&"value"in o?o.value:void 0},W=(t,e,o)=>{let n={type:t,at:o};if(!e||typeof e!="object")return n;try{for(let d of mt){let s=ht(gt(e,d));s!==void 0&&(n[d]=s)}}catch{}return n},V=t=>{let e=null,o=0,n=0;return{allow(d){let s=Math.floor(d/1e3);return s!==e&&(e=s,o=0),o<t?(o+=1,!0):(n+=1,!1)},dropped:()=>n}},q=(t,e)=>{let o=[],n=!1,d=0;return{push(s){n?e(s):o.length<t?o.push(s):d+=1},ready(){n=!0;let s=o;o=[],s.forEach(e)},dropped:()=>d}};var L=["bottom","top","left","right"],Z="bottom";var J={edge:{min:120,ratio:.45,max:520},side:{min:280,ratio:.4,max:480}},S=t=>t==="left"||t==="right",tt=t=>S(t)?J.side:J.edge,P=t=>tt(t).min,F=(t,e)=>Math.max(P(e),t-48),_=(t,e)=>{let{ratio:o,max:n}=tt(e);return Math.round(Math.min(t*o,n))},I=(t,e,o)=>{let n=Number.isFinite(t)?t:_(e,o);return Math.round(Math.min(Math.max(n,P(o)),F(e,o)))},et=(t,e,o,n,d)=>({bottom:d-o,top:o,left:e,right:n-e})[t],K=(t,e,o=!0)=>o?t==="open"?e:t==="collapsed"?34:0:0,ot=t=>Number.isFinite(t)&&t>0,xt=t=>Object.fromEntries(L.filter(e=>ot(t[e])).map(e=>[e,t[e]])),Q=()=>({dock:Z,sizes:{},reserve:null}),bt=t=>typeof t=="boolean"?t:null,Y=t=>{try{let e=JSON.parse(t);if(!e||typeof e!="object")return Q();let o=L.includes(e.dock)?e.dock:Z,n=bt(e.reserve);return e.sizes&&typeof e.sizes=="object"?{dock:o,sizes:xt(e.sizes),reserve:n}:{dock:o,sizes:ot(e.size)?{[o]:e.size}:{},reserve:n}}catch{return Q()}},rt=({dock:t,sizes:e,reserve:o})=>JSON.stringify(typeof o=="boolean"?{dock:t,sizes:e,reserve:o}:{dock:t,sizes:e}),M=(t,e)=>typeof t.reserve=="boolean"?t.reserve:e!=="false";var $=["ctrl","alt","shift","meta"],yt=/^(?:([a-z])|([0-9])|f([1-9]|1[0-2]))$/,wt=["INPUT","TEXTAREA","SELECT"],U=t=>{if(typeof t!="string")return null;let e=t.split("+"),o=e.pop(),n=yt.exec(o);if(!n||e.length===0||e.some(x=>!$.includes(x))||new Set(e).size!==e.length)return null;let[,d,s,l]=n,E={code:d?`Key${d.toUpperCase()}`:s?`Digit${s}`:`F${l}`,key:o};return $.forEach(x=>E[x]=e.includes(x)),E},St=(t,e)=>!!t&&e.code===t.code&&!!e.ctrlKey===t.ctrl&&!!e.altKey===t.alt&&!!e.shiftKey===t.shift&&!!e.metaKey===t.meta,Et=t=>!!t&&(wt.includes(String(t.tagName).toUpperCase())||t.isContentEditable===!0),nt=(t,e)=>St(t,e)&&!e.repeat&&!e.isComposing&&!Et(e.target),it=t=>{let e=U(t);if(!e)return"";let o={ctrl:"Ctrl",alt:"Alt",shift:"Shift",meta:"Meta"};return[...$.filter(n=>e[n]).map(n=>o[n]),e.key.toUpperCase()].join("+")};var dt="pdt:state",lt="pdt:open",ct="pdt:layout",kt=["open","collapsed","hidden"],zt=16,At=64,Dt={bottom:"ArrowUp",top:"ArrowDown",left:"ArrowRight",right:"ArrowLeft"},Pt={bottom:"ArrowDown",top:"ArrowUp",left:"ArrowLeft",right:"ArrowRight"},_t="pdt:",It=["bottom-left","top-right","top-left"],y=document.currentScript||document.querySelector("script[data-pdt-sid]"),Rt=()=>{try{let t=window.localStorage.getItem(dt);return kt.includes(t)?t:window.localStorage.getItem(lt)==="1"?"open":"collapsed"}catch{return"collapsed"}},Ct=t=>{try{window.localStorage.setItem(dt,t),window.localStorage.removeItem(lt)}catch{}},Tt=()=>{try{return Y(window.localStorage.getItem(ct))}catch{return Y(null)}},Ot=t=>{try{window.localStorage.setItem(ct,rt(t))}catch{}},Nt=`
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
  .pill.corner-bottom-left { right: auto; left: 12px; }
  .pill.corner-top-right { bottom: auto; top: 12px; }
  .pill.corner-top-left { right: auto; bottom: auto; left: 12px; top: 12px; }
  .pill:hover { transform: translateY(-1px); }
  .pill:focus-visible { outline: 2px solid #fd4f00; outline-offset: 2px; }
  .pill.visible { display: inline-flex; }
  @media (prefers-reduced-motion: reduce) { .frame, .pill, .handle::after { transition: none; } }
`,Ft=()=>{let t=document.documentElement,e=Object.fromEntries(["padding-left","padding-right"].map(n=>[n,{value:t.style.getPropertyValue(n),priority:t.style.getPropertyPriority(n)}])),o=n=>t.style.setProperty(n,e[n].value,e[n].priority);return(n,d)=>{["padding-left","padding-right"].forEach(s=>{if(o(s),s!==`padding-${n}`||d===0)return;let l=window.getComputedStyle(t).getPropertyValue(s)||"0px";t.style.setProperty(s,`calc(${l} + ${d}px)`,"important")})}},at="phoenix-dev-toolbar",st=()=>{let{pdtSid:t,pdtPath:e}=y.dataset;if(!t||!e||document.getElementById(at))return;let o=document.createElement("div");o.id=at,o.setAttribute("data-phx-update","ignore"),o.style.cssText="display:block;margin:0;padding:0;border:0;height:0";let n=o.attachShadow({mode:"open"}),d=document.createElement("style");d.textContent=Nt;let s=y.nonce||y.getAttribute("nonce");s&&d.setAttribute("nonce",s);let l=document.createElement("iframe");l.className="frame",l.title="Phoenix dev toolbar",l.src=`${e}/panel?sid=${encodeURIComponent(t)}`;let h=document.createElement("button");h.className="pill",h.type="button",h.textContent="dev toolbar";let E=y.dataset.pdtPill;It.includes(E)&&h.classList.add(`corner-${E}`);let x=y.dataset.pdtShortcut,k=U(x);h.title=k?`Show the dev toolbar (${it(x)})`:"Show the dev toolbar";let a=document.createElement("div");a.className="handle",a.tabIndex=0,a.title="Drag to resize, double click to reset",a.setAttribute("role","separator"),a.setAttribute("aria-label","Resize the dev toolbar"),n.append(d,l,a,h);let u=Rt(),g=Tt(),B=y.dataset.pdtReserve,i=g.dock,pt=Ft(),w=()=>S(i)?window.innerWidth:window.innerHeight,f=I(g.sizes[i],w(),i),z=(r,c={})=>l.contentWindow&&l.contentWindow.postMessage({type:_t+r,...c},window.location.origin),A=()=>z("state",{open:u==="open",dock:i,reserve:M(g,B),shortcut:k?x:null}),R=()=>Ot({dock:i,sizes:g.sizes,reserve:g.reserve}),ut=()=>{i==="top"&&document.body.firstChild!==o&&document.body.prepend(o),i!=="top"&&document.body.lastChild!==o&&document.body.append(o)},D=()=>{let r=K(u,f,M(g,B));o.style.setProperty("--pdt-extent",`${u==="open"?f:K("collapsed",f)}px`),o.style.height=S(i)?"0":`${r}px`,pt(i,S(i)?r:0),a.setAttribute("aria-valuemin",String(P(i))),a.setAttribute("aria-valuemax",String(F(w(),i))),a.setAttribute("aria-valuenow",String(f)),a.setAttribute("aria-valuetext",`${f} pixels`)},v=(r,c)=>{f=I(r,w(),i),D(),c&&(g.sizes[i]=f,R())},G=r=>{i=r,[l,a].forEach(c=>{L.forEach(m=>c.classList.toggle(`dock-${m}`,m===i))}),a.setAttribute("aria-orientation",S(i)?"vertical":"horizontal"),ut(),f=I(g.sizes[i],w(),i),D()},b=r=>{u=r,l.classList.toggle("hidden",u==="hidden"),a.classList.toggle("visible",u==="open"),h.classList.toggle("visible",u==="hidden"),D(),Ct(u),A()},X=V(20),j=()=>X.dropped()+C.dropped(),C=q(50,r=>z("client",{event:r,dropped:j()})),T=null,ft=()=>{T||(T=setTimeout(()=>{T=null,z("client",{event:null,dropped:j()})},1e3))};H.forEach(r=>window.addEventListener(r,c=>{try{let m=Date.now();X.allow(m)?C.push(W(r,c.detail,m)):ft()}catch{}},{passive:!0}));let p=null,O=()=>{p&&(p.frame&&cancelAnimationFrame(p.frame),p=null,l.classList.remove("dragging"),a.classList.remove("dragging"),v(f,!0))};a.addEventListener("pointerdown",r=>{r.button===0&&(r.preventDefault(),a.setPointerCapture(r.pointerId),p={frame:null,x:r.clientX,y:r.clientY},l.classList.add("dragging"),a.classList.add("dragging"))}),a.addEventListener("pointermove",r=>{p&&(p.x=r.clientX,p.y=r.clientY,!p.frame&&(p.frame=requestAnimationFrame(()=>{p&&(p.frame=null,v(et(i,p.x,p.y,window.innerWidth,window.innerHeight),!1))})))}),a.addEventListener("pointerup",O),a.addEventListener("pointercancel",O),a.addEventListener("lostpointercapture",O),a.addEventListener("dblclick",()=>v(_(w(),i),!0)),a.addEventListener("keydown",r=>{let c=r.shiftKey?At:zt,m={[Dt[i]]:f+c,[Pt[i]]:f-c,Home:_(w(),i)}[r.key];m!==void 0&&(r.preventDefault(),v(m,!0))});let N=null;window.addEventListener("resize",()=>{N||(N=requestAnimationFrame(()=>{N=null,v(g.sizes[i],!1)}))},{passive:!0}),k&&window.addEventListener("keydown",r=>{try{if(!nt(k,r))return;r.preventDefault(),b(u==="collapsed"?"open":"collapsed")}catch{}}),h.addEventListener("click",()=>{b("collapsed"),l.focus(),z("focus")}),l.addEventListener("load",()=>{A(),C.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==l.contentWindow)return;let c=r.data&&r.data.type;if(c==="pdt:toggle"&&b(u==="open"?"collapsed":"open"),c==="pdt:open"&&b("open"),c==="pdt:close"&&b("collapsed"),c==="pdt:hide"){let m=n.activeElement===l;b("hidden"),m&&h.focus()}c==="pdt:dock"&&L.includes(r.data.dock)&&(G(r.data.dock),R(),A()),c==="pdt:reserve"&&typeof r.data.reserve=="boolean"&&(g.reserve=r.data.reserve,D(),R(),A())}),G(i),b(u)};y&&window.top===window&&(document.body?st():document.addEventListener("DOMContentLoaded",st,{once:!0}));})();
