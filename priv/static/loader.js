(()=>{var x=["phx:page-loading-start","phx:page-loading-stop","phx:navigate"],T=["kind","to","href","patch","pop"];var R=e=>{if(typeof e=="string")return e.length>256?e.slice(0,256)+"\u2026":e;if(typeof e=="boolean"||typeof e=="number"&&Number.isFinite(e))return e},I=(e,n)=>{let o=Object.getOwnPropertyDescriptor(e,n);return o&&"value"in o?o.value:void 0},w=(e,n,o)=>{let i={type:e,at:o};if(!n||typeof n!="object")return i;try{for(let d of T){let t=R(I(n,d));t!==void 0&&(i[d]=t)}}catch{}return i},b=e=>{let n=null,o=0,i=0;return{allow(d){let t=Math.floor(d/1e3);return t!==n&&(n=t,o=0),o<e?(o+=1,!0):(i+=1,!1)},dropped:()=>i}},E=(e,n)=>{let o=[],i=!1,d=0;return{push(t){i?n(t):o.length<e?o.push(t):d+=1},ready(){i=!0;let t=o;o=[],t.forEach(n)},dropped:()=>d}};var y="pdt:state",_="pdt:open",A=["open","collapsed","hidden"],C=34,P="pdt:",L=document.currentScript||document.querySelector("script[data-pdt-sid]"),F=()=>{try{let e=window.localStorage.getItem(y);return A.includes(e)?e:window.localStorage.getItem(_)==="1"?"open":"collapsed"}catch{return"collapsed"}},M=e=>{try{window.localStorage.setItem(y,e),window.localStorage.removeItem(_)}catch{}},O=`
  :host { all: initial; }
  .frame {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;
    width: 100%; height: ${C}px; border: 0; margin: 0; padding: 0;
    box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12);
    background: transparent; color-scheme: normal;
    transition: height 120ms ease-out;
  }
  .frame.open { height: min(45vh, 520px); }
  .frame.hidden { display: none; }
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
  @media (prefers-reduced-motion: reduce) { .frame, .pill { transition: none; } }
`,S=()=>{let{pdtSid:e,pdtPath:n}=L.dataset;if(!e||!n)return;let o=document.createElement("div");o.id="phoenix-dev-toolbar",o.setAttribute("data-phx-update","ignore");let i=o.attachShadow({mode:"open"}),d=document.createElement("style");d.textContent=O;let t=document.createElement("iframe");t.className="frame",t.title="Phoenix dev toolbar",t.src=`${n}/panel?sid=${encodeURIComponent(e)}`;let a=document.createElement("button");a.className="pill",a.type="button",a.textContent="dev toolbar",a.title="Show the dev toolbar",i.append(d,t,a),document.body.appendChild(o);let s=F(),l=(r,p={})=>t.contentWindow&&t.contentWindow.postMessage({type:P+r,...p},window.location.origin),c=r=>{s=r,t.classList.toggle("open",s==="open"),t.classList.toggle("hidden",s==="hidden"),a.classList.toggle("visible",s==="hidden"),M(s),l("state",{open:s==="open"})},m=b(20),g=()=>m.dropped()+u.dropped(),u=E(50,r=>l("client",{event:r,dropped:g()})),f=null,v=()=>{f||(f=setTimeout(()=>{f=null,l("client",{event:null,dropped:g()})},1e3))};x.forEach(r=>window.addEventListener(r,p=>{try{let h=Date.now();m.allow(h)?u.push(w(r,p.detail,h)):v()}catch{}},{passive:!0})),a.addEventListener("click",()=>c("collapsed")),t.addEventListener("load",()=>{l("state",{open:s==="open"}),u.ready()}),window.addEventListener("message",r=>{if(r.origin!==window.location.origin||r.source!==t.contentWindow)return;let p=r.data&&r.data.type;p==="pdt:toggle"&&c(s==="open"?"collapsed":"open"),p==="pdt:open"&&c("open"),p==="pdt:close"&&c("collapsed"),p==="pdt:hide"&&c("hidden")}),c(s)};L&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?S():document.addEventListener("DOMContentLoaded",S,{once:!0}));})();
