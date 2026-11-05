(()=>{var m="pdt:state",h="pdt:open",f=["open","collapsed","hidden"];var x="pdt:",g=document.currentScript||document.querySelector("script[data-pdt-sid]"),w=()=>{try{let o=window.localStorage.getItem(m);return f.includes(o)?o:window.localStorage.getItem(h)==="1"?"open":"collapsed"}catch{return"collapsed"}},b=o=>{try{window.localStorage.setItem(m,o),window.localStorage.removeItem(h)}catch{}},S=`
  :host { all: initial; }
  .frame {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;
    width: 100%; height: 34px; border: 0; margin: 0; padding: 0;
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
`,c=()=>{let{pdtSid:o,pdtPath:r}=g.dataset;if(!o||!r)return;let s=document.createElement("div");s.id="phoenix-dev-toolbar",s.setAttribute("data-phx-update","ignore");let u=s.attachShadow({mode:"open"}),p=document.createElement("style");p.textContent=S;let e=document.createElement("iframe");e.className="frame",e.title="Phoenix dev toolbar",e.src=`${r}/panel?sid=${encodeURIComponent(o)}`;let i=document.createElement("button");i.className="pill",i.type="button",i.textContent="dev toolbar",i.title="Show the dev toolbar",u.append(p,e,i),document.body.appendChild(s);let t=w(),l=(n,a={})=>e.contentWindow&&e.contentWindow.postMessage({type:x+n,...a},window.location.origin),d=n=>{t=n,e.classList.toggle("open",t==="open"),e.classList.toggle("hidden",t==="hidden"),i.classList.toggle("visible",t==="hidden"),b(t),l("state",{open:t==="open"})};i.addEventListener("click",()=>d("collapsed")),e.addEventListener("load",()=>l("state",{open:t==="open"})),window.addEventListener("message",n=>{if(n.origin!==window.location.origin||n.source!==e.contentWindow)return;let a=n.data&&n.data.type;a==="pdt:toggle"&&d(t==="open"?"collapsed":"open"),a==="pdt:open"&&d("open"),a==="pdt:close"&&d("collapsed"),a==="pdt:hide"&&d("hidden")}),d(t)};g&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?c():document.addEventListener("DOMContentLoaded",c,{once:!0}));})();
