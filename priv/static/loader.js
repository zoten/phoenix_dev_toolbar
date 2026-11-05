(()=>{var l="pdt:open";var u="pdt:",m=document.currentScript||document.querySelector("script[data-pdt-sid]"),w=()=>{try{return window.localStorage.getItem(l)==="1"}catch{return!1}},g=n=>{try{window.localStorage.setItem(l,n?"1":"0")}catch{}},f=`
  :host { all: initial; }
  .frame {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;
    width: 100%; height: 34px; border: 0; margin: 0; padding: 0;
    box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12);
    background: transparent; color-scheme: normal;
    transition: height 120ms ease-out;
  }
  .frame.open { height: min(45vh, 520px); }
  @media (prefers-reduced-motion: reduce) { .frame { transition: none; } }
`,p=()=>{let{pdtSid:n,pdtPath:a}=m.dataset;if(!n||!a)return;let i=document.createElement("div");i.id="phoenix-dev-toolbar",i.setAttribute("data-phx-update","ignore");let h=i.attachShadow({mode:"open"}),s=document.createElement("style");s.textContent=f;let t=document.createElement("iframe");t.className="frame",t.title="Phoenix dev toolbar",t.src=`${a}/panel?sid=${encodeURIComponent(n)}`,h.append(s,t),document.body.appendChild(i);let o=w(),c=(e,d={})=>t.contentWindow&&t.contentWindow.postMessage({type:u+e,...d},window.location.origin),r=e=>{o=e,t.classList.toggle("open",o),g(o),c("state",{open:o})};t.addEventListener("load",()=>c("state",{open:o})),window.addEventListener("message",e=>{if(e.origin!==window.location.origin||e.source!==t.contentWindow)return;let d=e.data&&e.data.type;d==="pdt:toggle"&&r(!o),d==="pdt:open"&&r(!0),d==="pdt:close"&&r(!1)}),r(o)};m&&window.top===window&&!window.__phoenixDevToolbar&&(window.__phoenixDevToolbar=!0,document.body?p():document.addEventListener("DOMContentLoaded",p,{once:!0}));})();
