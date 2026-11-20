// NAME: Notch Player
// AUTHOR: Haeryz
// DESCRIPTION: Dynamic-Island player in the MacBook notch (with the companion app) or inside the Spotify window.
// VERSION: 2.0.0


(function NotchPlayer() {
  const S = window.Spicetify;
  if (!S?.Player?.data || !S?.Platform || !S?.LocalStorage || !document.body) {
    setTimeout(NotchPlayer, 300);
    return;
  }

  /* ---------------------------------------------------------------- settings */
  const KEY = "notch-player:settings";
  const DEFAULTS = {
    enabled: true,
    position: "center", // center | left | right
    expandOnSongChange: false, // opt-in: expand briefly when the song changes
    showVisualizer: true,
    showUpNext: true,
    tintFromArt: true,
    hideNativeBar: false, // hide Spotify's bottom now-playing bar
  };
  let cfg = { ...DEFAULTS };
  try {
    cfg = { ...DEFAULTS, ...JSON.parse(S.LocalStorage.get(KEY) || "{}") };
    delete cfg.peekOnChange; // legacy key (defaulted on); replaced by opt-in expandOnSongChange
  } catch (_) {}
  const save = () => S.LocalStorage.set(KEY, JSON.stringify(cfg));

  /* ---------------------------------------------------------------- styles */
  const css = `
  #np-root{--np-accent:#1ed760;--np-glow:rgba(30,215,96,.35);position:fixed;top:6px;z-index:2147483000;
    font-family:var(--font-family,"SF Pro Text",-apple-system,system-ui,sans-serif);color:#fff;user-select:none;
    transition:left .35s,right .35s,transform .35s}
  #np-root.np-pos-center{left:50%;transform:translateX(-50%)}
  #np-root.np-pos-left{left:90px}
  #np-root.np-pos-right{right:16px}
  #np-root.np-hidden{display:none}
  .np-island{position:relative;isolation:isolate;background:#000;border-radius:22px;overflow:hidden;width:220px;height:36px;
    box-shadow:inset 0 -1px 0 rgba(255,255,255,.07),0 0 0 1px rgba(255,255,255,.05),0 8px 30px rgba(0,0,0,.45);
    transition:width .5s cubic-bezier(.32,1.2,.5,1),height .5s cubic-bezier(.32,1.2,.5,1),border-radius .5s,box-shadow .5s;
    -webkit-app-region:no-drag}
  /* ambient album-art glow */
  .np-island::before{content:"";position:absolute;inset:-25%;z-index:-1;pointer-events:none;
    background:var(--np-art,none) center/cover no-repeat;filter:blur(40px) saturate(1.7) brightness(.85);
    -webkit-mask-image:linear-gradient(180deg,transparent 10%,#000 60%);mask-image:linear-gradient(180deg,transparent 10%,#000 60%);
    opacity:0;transition:opacity .6s}
  #np-root.np-open .np-island::before{opacity:.36}
  #np-root.np-open .np-island{width:400px;height:var(--np-open-h,220px);border-radius:32px;
    box-shadow:inset 0 -1px 0 rgba(255,255,255,.14),0 0 0 1px rgba(255,255,255,.07),0 3px 8px rgba(0,0,0,.55),0 12px 44px var(--np-glow)}
  #np-root.np-pulse .np-island{animation:np-pulse .6s cubic-bezier(.34,1.56,.64,1)}
  @keyframes np-pulse{40%{transform:scale(1.05)}}
  /* compact */
  .np-compact{display:flex;align-items:center;gap:8px;height:36px;padding:0 10px 0 4px;transition:opacity .2s}
  #np-root.np-open .np-compact{opacity:0;pointer-events:none;position:absolute}
  .np-cring{--np-p:0;width:28px;height:28px;border-radius:9px;flex:none;display:grid;place-items:center;
    background:conic-gradient(var(--np-accent) calc(var(--np-p) * 1turn),rgba(255,255,255,.12) 0)}
  .np-cring img{width:23px;height:23px;border-radius:6.5px;object-fit:cover;background:#222;box-shadow:0 0 0 1px #000;
    transition:opacity .18s,transform .45s cubic-bezier(.34,1.4,.5,1)}
  #np-root.np-paused .np-cring img{transform:scale(.86)}
  .np-ctitle{flex:1;min-width:0;font-size:12px;font-weight:600;white-space:nowrap;overflow:hidden;
    mask-image:linear-gradient(90deg,#000 85%,transparent)}
  .np-ctitle span,.np-title span{display:inline-block}
  .np-marquee span{animation:np-marq 9s ease-in-out infinite alternate}
  @keyframes np-marq{0%,15%{transform:translateX(0)}85%,100%{transform:translateX(var(--np-shift,0))}}
  /* visualizer */
  .np-viz{display:flex;align-items:center;gap:2.5px;height:16px;flex:none}
  .np-viz i{display:block;width:3px;height:3px;border-radius:2px;opacity:.45;transition:height .3s,opacity .3s;
    background:linear-gradient(var(--np-accent),color-mix(in srgb,var(--np-accent) 55%,transparent))}
  .np-viz.np-playing i{opacity:1;animation:np-bar 1s ease-in-out infinite}
  .np-viz i:nth-child(2){animation-delay:-.6s!important;animation-duration:.8s!important}
  .np-viz i:nth-child(3){animation-delay:-.3s!important;animation-duration:1.1s!important}
  .np-viz i:nth-child(4){animation-delay:-.9s!important;animation-duration:.7s!important}
  @keyframes np-bar{0%,100%{height:25%}50%{height:100%}}
  .np-noviz .np-viz{display:none}
  /* bars driven by the track's audio analysis */
  #np-root.np-live .np-viz i{animation:none!important;transition:none;opacity:1}
  /* expanded */
  /* content scales/fades on the island's own curve and duration so both move as one */
  .np-full{opacity:0;padding:16px 18px 14px;pointer-events:none;transform:scale(.92);transform-origin:top center;
    transition:opacity .3s,transform .5s cubic-bezier(.32,1.2,.5,1)}
  #np-root.np-open .np-full{opacity:1;transform:none;pointer-events:auto;
    transition:opacity .4s,transform .5s cubic-bezier(.32,1.2,.5,1)}
  .np-top{display:flex;gap:14px;align-items:center}
  .np-art{width:64px;height:64px;border-radius:14px;object-fit:cover;flex:none;background:#222;cursor:pointer;
    box-shadow:0 0 0 .5px rgba(255,255,255,.1),0 6px 20px var(--np-glow);
    transition:opacity .18s,transform .5s cubic-bezier(.34,1.4,.5,1),box-shadow .5s}
  #np-root.np-paused .np-art{transform:scale(.88);box-shadow:0 0 0 .5px rgba(255,255,255,.1),0 2px 8px rgba(0,0,0,.4)}
  .np-fade{opacity:0!important}
  .np-meta{flex:1;min-width:0}
  .np-title{font-size:15px;font-weight:650;white-space:nowrap;overflow:hidden;cursor:pointer}
  .np-title.np-marquee{mask-image:linear-gradient(90deg,transparent,#000 4%,#000 88%,transparent)}
  .np-artist,.np-album{font-size:12.5px;font-weight:500;color:rgba(255,255,255,.68);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
  .np-album{font-size:9.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:rgba(255,255,255,.38);margin-top:3px}
  .np-artist:hover,.np-album:hover,.np-title:hover{text-decoration:underline}
  .np-side{display:flex;flex-direction:column;align-items:flex-end;gap:8px;flex:none}
  .np-badge{font-size:10px;font-weight:500;color:rgba(255,255,255,.6);display:flex;align-items:center;gap:4px;max-width:120px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:3px 8px;border-radius:999px;background:rgba(255,255,255,.08)}
  .np-seek{display:flex;align-items:center;gap:8px;margin-top:12px;font-size:10.5px;font-weight:500;color:rgba(255,255,255,.55);
    font-variant-numeric:tabular-nums}
  .np-bar{flex:1;height:5px;border-radius:3px;background:rgba(255,255,255,.16);position:relative;cursor:pointer;transition:height .15s}
  .np-bar:hover{height:7px}
  .np-fill{position:absolute;inset:0 auto 0 0;border-radius:3px;background:rgba(255,255,255,.92);width:0;transition:background .15s,box-shadow .15s}
  .np-bar:hover .np-fill{background:var(--np-accent);box-shadow:0 0 8px var(--np-glow)}
  .np-vbar{flex:none;width:70px;height:4px}
  .np-vbar:hover{height:6px}
  .np-ctrls{display:flex;align-items:center;justify-content:space-between;margin-top:8px}
  .np-btn{background:none;border:0;color:#fff;cursor:pointer;width:34px;height:34px;border-radius:50%;
    display:grid;place-items:center;opacity:.9;transition:background .15s,transform .15s,opacity .15s;padding:0}
  .np-btn:hover{background:rgba(255,255,255,.09);opacity:1;transform:scale(1.06)}
  .np-btn:active{transform:scale(.88)}
  .np-btn svg{width:18px;height:18px;fill:currentColor;animation:np-pop .3s cubic-bezier(.34,1.56,.64,1)}
  @keyframes np-pop{from{transform:scale(.5);opacity:0}}
  .np-btn.np-big{width:42px;height:42px}
  .np-btn.np-big svg{width:24px;height:24px}
  .np-btn.np-dim{opacity:.4}
  .np-btn.np-dim:hover{opacity:.75}
  .np-btn.np-on{color:var(--np-accent);opacity:1}
  .np-vol{display:flex;align-items:center;gap:4px}
  .np-next{display:flex;align-items:center;gap:9px;margin-top:10px;padding:5px 10px 5px 5px;border-radius:10px;
    background:rgba(255,255,255,.05);font-size:11.5px;color:rgba(255,255,255,.45);cursor:pointer;min-width:0;transition:background .15s}
  .np-next:hover{background:rgba(255,255,255,.1)}
  .np-next img{width:24px;height:24px;border-radius:6px;flex:none;background:#222;object-fit:cover}
  .np-next em{font-style:normal;font-size:9px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:rgba(255,255,255,.4);flex:none}
  .np-next b{color:rgba(255,255,255,.88);font-weight:600}
  .np-next span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .np-next>span{flex:1;min-width:0}
  .np-chev{width:10px;height:10px;fill:currentColor;flex:none;opacity:.5;transition:transform .15s,opacity .15s}
  .np-next:hover .np-chev{opacity:1;transform:translateX(2px)}
  .np-nonext .np-next{display:none}
  body.np-hide-native .Root__now-playing-bar{display:none!important}
  `;
  const style = document.createElement("style");
  style.id = "np-style";
  style.textContent = css;
  document.head.appendChild(style);

  /* ---------------------------------------------------------------- icons */
  const P = {
    play: "M7 4.5v15a1 1 0 0 0 1.5.86l12.6-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z",
    pause: "M6 4h4v16H6zM14 4h4v16h-4z",
    next: "M5 5.5v13a1 1 0 0 0 1.55.83L15 13.6V18a1 1 0 0 0 2 0V6a1 1 0 0 0-2 0v4.4L6.55 4.67A1 1 0 0 0 5 5.5zM18 5h1.5v14H18z",
    prev: "M19 5.5v13a1 1 0 0 1-1.55.83L9 13.6V18a1 1 0 0 1-2 0V6a1 1 0 0 1 2 0v4.4l8.45-5.73A1 1 0 0 1 19 5.5zM4.5 5H6v14H4.5z",
    shuffle:
      "M17 3l4 4-4 4V8h-2.2l-3.1 4 3.1 4H17v-3l4 4-4 4v-3h-3.2l-3.6-4.6L6.6 18H3v-2h2.6l3.1-4-3.1-4H3V6h3.6l3.6 4.6L13.8 6H17z",
    repeat: "M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2z",
    repeat1:
      "M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2zM11 15h1.5V9h-1l-2 1v1.2l1.5-.7z",
    heart:
      "M12 20.5l-1.4-1.3C5.4 14.5 2 11.4 2 7.6 2 4.5 4.4 2 7.5 2c1.7 0 3.4.8 4.5 2.1C13.1 2.8 14.8 2 16.5 2 19.6 2 22 4.5 22 7.6c0 3.8-3.4 6.9-8.6 11.6z",
    heartO:
      "M16.5 2c-1.7 0-3.4.8-4.5 2.1C10.9 2.8 9.2 2 7.5 2 4.4 2 2 4.5 2 7.6c0 3.8 3.4 6.9 8.6 11.6L12 20.5l1.4-1.3C18.6 14.5 22 11.4 22 7.6 22 4.5 19.6 2 16.5 2zm-4.4 15.7l-.1.1-.1-.1C7.1 13.4 4 10.6 4 7.6 4 5.6 5.5 4 7.5 4c1.5 0 3 1 3.6 2.4h1.9C13.5 5 15 4 16.5 4c2 0 3.5 1.6 3.5 3.6 0 3-3.1 5.8-7.9 10.1z",
    vol: "M3 9v6h4l5 5V4L7 9zm13.5 3A4.5 4.5 0 0 0 14 8v8a4.5 4.5 0 0 0 2.5-4zM14 3.2v2.1a7 7 0 0 1 0 13.4v2.1a9 9 0 0 0 0-17.6z",
    mute: "M3 9v6h4l5 5V4L7 9zm18.6 6.2L19.4 13l2.2-2.2-1.4-1.4L18 11.6l-2.2-2.2-1.4 1.4 2.2 2.2-2.2 2.2 1.4 1.4 2.2-2.2 2.2 2.2z",
    device:
      "M4 6h16v10H4zm-2-2v14h8v2h4v-2h8V4zM6 8v6h12V8z",
    lyrics: "M4 5h16v2H4zm0 4h10v2H4zm0 4h16v2H4zm0 4h10v2H4z",
  };
  const icon = (d) => `<svg viewBox="0 0 24 24"><path d="${d}"/></svg>`;

  /* ---------------------------------------------------------------- DOM */
  const root = document.createElement("div");
  root.id = "np-root";
  root.innerHTML = `
    <div class="np-island">
      <div class="np-compact">
        <div class="np-cring"><img class="np-cart" alt=""></div>
        <div class="np-ctitle"><span></span></div>
        <div class="np-viz">${"<i></i>".repeat(4)}</div>
      </div>
      <div class="np-full">
        <div class="np-top">
          <img class="np-art" alt="" title="Go to album">
          <div class="np-meta">
            <div class="np-title" title="Go to album"><span></span></div>
            <div class="np-artist" title="Go to artist"></div>
            <div class="np-album" title="Go to album"></div>
          </div>
          <div class="np-side">
            <div class="np-viz">${"<i></i>".repeat(4)}</div>
            <div class="np-badge" title="Playing on"><svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="${P.device}"/></svg><span class="np-dev"></span></div>
          </div>
        </div>
        <div class="np-seek">
          <span class="np-cur">0:00</span>
          <div class="np-bar"><div class="np-fill"></div></div>
          <span class="np-dur">0:00</span>
        </div>
        <div class="np-ctrls">
          <button class="np-btn np-like" title="Save to Liked Songs"></button>
          <button class="np-btn np-shuffle" title="Shuffle">${icon(P.shuffle)}</button>
          <button class="np-btn np-prev" title="Previous">${icon(P.prev)}</button>
          <button class="np-btn np-big np-play" title="Play/Pause"></button>
          <button class="np-btn np-nextb" title="Next">${icon(P.next)}</button>
          <button class="np-btn np-repeat" title="Repeat"></button>
          <div class="np-vol">
            <button class="np-btn np-volb" title="Mute"></button>
            <div class="np-bar np-vbar" title="Volume"><div class="np-fill"></div></div>
          </div>
        </div>
        <div class="np-next" title="Up next">
          <img class="np-nart" alt=""><em>Up next</em><span><b class="np-ntitle"></b> <span class="np-nartist"></span></span>
          <svg class="np-chev" viewBox="0 0 24 24"><path d="M8.6 5.4 10 4l8 8-8 8-1.4-1.4L15.2 12z"/></svg>
        </div>
      </div>
    </div>`;
  document.body.appendChild(root);

  const $ = (s) => root.querySelector(s);
  const el = {
    cart: $(".np-cart"),
    ctitleWrap: $(".np-ctitle"),
    ctitle: $(".np-ctitle span"),
    vizzes: root.querySelectorAll(".np-viz"),
    art: $(".np-art"),
    title: $(".np-title"),
    titleSpan: $(".np-title span"),
    cring: $(".np-cring"),
    artist: $(".np-artist"),
    album: $(".np-album"),
    dev: $(".np-dev"),
    badge: $(".np-badge"),
    cur: $(".np-cur"),
    dur: $(".np-dur"),
    bar: $(".np-seek .np-bar"),
    fill: $(".np-seek .np-fill"),
    like: $(".np-like"),
    shuffle: $(".np-shuffle"),
    prev: $(".np-prev"),
    play: $(".np-play"),
    next: $(".np-nextb"),
    repeat: $(".np-repeat"),
    volb: $(".np-volb"),
    vbar: $(".np-vbar"),
    vfill: $(".np-vbar .np-fill"),
    upnext: $(".np-next"),
    nart: $(".np-nart"),
    ntitle: $(".np-ntitle"),
    nartist: $(".np-nartist"),
  };

  /* ---------------------------------------------------------------- helpers */
  const fmt = (ms) => {
    if (!ms || ms < 0) ms = 0;
    const s = Math.floor(ms / 1000);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = String(s % 60).padStart(2, "0");
    return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
  };
  const img = (u) => (u ? u.replace("spotify:image:", "https://i.scdn.co/image/") : "");
  const go = (uri) => {
    if (!uri) return;
    try {
      const u = S.URI.from(uri);
      const path = u?.toURLPath?.(true) || `/${uri.split(":").slice(1).join("/")}`;
      S.Platform.History.push(path);
    } catch (_) {}
  };
  const safe = (fn, fb) => {
    try {
      const v = fn();
      return v === undefined ? fb : v;
    } catch (_) {
      return fb;
    }
  };

  // Swap an icon only when it actually changes, so the pop animation doesn't replay every tick.
  const setIcon = (btn, d) => {
    if (btn.dataset.d === d) return;
    btn.dataset.d = d;
    btn.innerHTML = icon(d);
  };
  // Crossfade an <img> to a new source once it has loaded.
  const swapImg = (im, src) => {
    if (!src || im.dataset.src === src) return;
    im.dataset.src = src;
    const pre = new Image();
    pre.onload = () => {
      if (im.dataset.src !== src) return;
      if (!im.getAttribute("src")) return void (im.src = src);
      im.classList.add("np-fade");
      setTimeout(() => {
        im.src = src;
        im.classList.remove("np-fade");
      }, 180);
    };
    pre.src = src;
  };
  // Scroll overflowing text back and forth (np-marq keyframes, distance via --np-shift).
  // Measuring only means something while the element is laid out at its real width.
  const marquee = (wrap, span) =>
    requestAnimationFrame(() => {
      const over = wrap.clientWidth ? span.scrollWidth - wrap.clientWidth : 0;
      wrap.classList.toggle("np-marquee", over > 4);
      wrap.style.setProperty("--np-shift", `${-(over + 14)}px`);
    });

  /* ---------------------------------------------------------------- render */
  let current = { uri: "", albumUri: "", artistUri: "" };

  function renderTrack() {
    const item = S.Player.data?.item;
    if (!item) {
      root.classList.add("np-hidden");
      return;
    }
    if (cfg.enabled) root.classList.remove("np-hidden");
    const m = item.metadata || {};
    const title = m.title || item.name || "";
    const artist =
      m.artist_name ||
      (item.artists || []).map((a) => a.name).join(", ") ||
      "";
    const album = m.album_title || item.album?.name || "";
    const art = img(m.image_xlarge_url || m.image_large_url || m.image_url || item.album?.images?.[0]?.url);

    current = {
      uri: item.uri,
      albumUri: m.album_uri || item.album?.uri,
      artistUri: m.artist_uri || item.artists?.[0]?.uri,
    };

    el.ctitle.textContent = artist ? `${title} — ${artist}` : title;
    el.titleSpan.textContent = title;
    el.artist.textContent = artist;
    el.album.textContent = album;
    if (art) {
      swapImg(el.cart, art);
      swapImg(el.art, art);
      root.style.setProperty("--np-art", `url("${art}")`);
    }
    marquee(el.ctitleWrap, el.ctitle);
    if (root.classList.contains("np-open")) marquee(el.title, el.titleSpan);
    else el.title.classList.remove("np-marquee"); // re-measured on open

    el.dur.textContent = fmt(S.Player.getDuration());
    renderState();
    renderUpNext();
    renderDevice();
    tint(item.uri);
  }

  function renderState() {
    const playing = safe(() => S.Player.isPlaying(), false);
    setIcon(el.play, playing ? P.pause : P.play);
    root.classList.toggle("np-paused", !playing);
    el.vizzes.forEach((v) => v.classList.toggle("np-playing", playing));

    const liked = safe(() => S.Player.getHeart(), false);
    setIcon(el.like, liked ? P.heart : P.heartO);
    el.like.classList.toggle("np-on", liked);

    const shuf = safe(() => S.Player.getShuffle(), false);
    el.shuffle.classList.toggle("np-on", !!shuf);
    el.shuffle.classList.toggle("np-dim", !shuf);

    const rep = safe(() => S.Player.getRepeat(), 0); // 0 off, 1 context, 2 track
    setIcon(el.repeat, rep === 2 ? P.repeat1 : P.repeat);
    el.repeat.classList.toggle("np-on", rep > 0);
    el.repeat.classList.toggle("np-dim", rep === 0);

    renderVolume();
  }

  function renderVolume() {
    const v = safe(() => S.Player.getVolume(), 1);
    if (!vdragging) el.vfill.style.width = `${Math.round(v * 100)}%`;
    setIcon(el.volb, v === 0 ? P.mute : P.vol);
  }

  function renderProgress() {
    if (dragging || bridged) return;
    const p = safe(() => S.Player.getProgress(), 0);
    const d = safe(() => S.Player.getDuration(), 0);
    el.cur.textContent = fmt(p);
    el.dur.textContent = fmt(d);
    el.fill.style.width = d ? `${Math.min(100, (p / d) * 100)}%` : "0%";
    el.cring.style.setProperty("--np-p", d ? Math.min(1, p / d).toFixed(4) : 0);
  }

  function renderUpNext() {
    const nt = safe(() => S.Queue?.nextTracks?.[0]?.contextTrack, null);
    const md = nt?.metadata;
    const show = cfg.showUpNext && md && md.title;
    root.classList.toggle("np-nonext", !show);
    root.style.setProperty("--np-open-h", show ? "220px" : "180px");
    if (!show) return;
    el.ntitle.textContent = md.title;
    el.nartist.textContent = md.artist_name ? `· ${md.artist_name}` : "";
    const u = img(md.image_url || md.image_small_url || md.image_large_url);
    if (u) el.nart.src = u;
  }

  function renderDevice() {
    const name = safe(
      () =>
        S.Platform.ConnectAPI?.state?.activeDevice?.name ||
        S.Platform.ConnectAPI?.getState?.()?.activeDevice?.name,
      ""
    );
    el.dev.textContent = name || "This computer";
    el.badge.title = `Playing on ${name || "this computer"}`;
  }

  async function tint(uri) {
    if (!cfg.tintFromArt) return setAccent("#1ed760");
    try {
      const c = await S.colorExtractor(uri);
      if (uri !== current.uri) return;
      setAccent(c.VIBRANT || c.LIGHT_VIBRANT || c.PROMINENT || "#1ed760");
    } catch (_) {
      setAccent("#1ed760");
    }
  }
  function setAccent(hex) {
    root.style.setProperty("--np-accent", hex);
    const h = hex.replace("#", "");
    const n = parseInt(h.length === 3 ? h.replace(/./g, "$&$&") : h, 16);
    root.style.setProperty("--np-glow", `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},.35)`);
  }

  function applySettings() {
    root.classList.remove("np-pos-center", "np-pos-left", "np-pos-right");
    root.classList.add(`np-pos-${cfg.position}`);
    root.classList.toggle("np-noviz", !cfg.showVisualizer);
    root.classList.toggle("np-hidden", !cfg.enabled || !S.Player.data?.item);
    document.body.classList.toggle("np-hide-native", cfg.enabled && cfg.hideNativeBar);
    renderUpNext();
    tint(current.uri);
  }

  /* ---------------------------------------------------------------- open / close */
  let hovering = false;
  let bridged = false;
  let peekTimer = null;
  const setOpen = (o) => {
    root.classList.toggle("np-open", o);
    if (o) setTimeout(() => marquee(el.title, el.titleSpan), 520); // measure once the island has widened
  };
  root.addEventListener("mouseenter", () => {
    hovering = true;
    clearTimeout(peekTimer);
    renderUpNext();
    renderDevice();
    setOpen(true);
  });
  root.addEventListener("mouseleave", () => {
    hovering = false;
    if (!dragging) setOpen(false);
  });
  // Song change: a small bounce of the compact pill — never opens the full player.
  function pulse() {
    if (root.classList.contains("np-open")) return;
    root.classList.remove("np-pulse");
    void root.offsetWidth;
    root.classList.add("np-pulse");
  }
  function peek() {
    if (!cfg.expandOnSongChange || hovering) return;
    setOpen(true);
    clearTimeout(peekTimer);
    peekTimer = setTimeout(() => !hovering && setOpen(false), 3500);
  }

  /* ---------------------------------------------------------------- controls */
  el.play.onclick = () => S.Player.togglePlay();
  el.next.onclick = () => S.Player.next();
  el.prev.onclick = () => S.Player.back();
  el.shuffle.onclick = () => {
    S.Player.toggleShuffle();
    setTimeout(renderState, 150);
  };
  el.repeat.onclick = () => {
    S.Player.toggleRepeat();
    setTimeout(renderState, 150);
  };
  el.like.onclick = () => {
    S.Player.toggleHeart();
    setTimeout(renderState, 250);
  };
  let lastVol = 0.5;
  el.volb.onclick = () => {
    const v = S.Player.getVolume();
    if (v > 0) {
      lastVol = v;
      S.Player.setVolume(0);
    } else S.Player.setVolume(lastVol || 0.5);
    setTimeout(renderVolume, 100);
  };
  // volume scrubbing
  let vdragging = false;
  const vratio = (e) => {
    const r = el.vbar.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
  };
  const setVol = (v) => {
    S.Player.setVolume(v);
    el.vfill.style.width = `${Math.round(v * 100)}%`;
    setIcon(el.volb, v === 0 ? P.mute : P.vol);
  };
  el.vbar.addEventListener("pointerdown", (e) => {
    vdragging = true;
    el.vbar.setPointerCapture(e.pointerId);
    setVol(vratio(e));
  });
  el.vbar.addEventListener("pointermove", (e) => vdragging && setVol(vratio(e)));
  el.vbar.addEventListener("pointerup", () => {
    vdragging = false;
    if (!hovering) setOpen(false);
  });
  root.addEventListener(
    "wheel",
    (e) => {
      if (!root.classList.contains("np-open")) return;
      e.preventDefault();
      const v = Math.max(0, Math.min(1, S.Player.getVolume() - Math.sign(e.deltaY) * 0.05));
      S.Player.setVolume(v);
      setTimeout(renderVolume, 50);
    },
    { passive: false }
  );
  el.title.onclick = () => go(current.albumUri);
  el.art.onclick = () => go(current.albumUri);
  el.album.onclick = () => go(current.albumUri);
  el.artist.onclick = () => go(current.artistUri);
  el.upnext.onclick = () => S.Platform.History.push("/queue");
  root.querySelector(".np-compact").ondblclick = () => S.Player.togglePlay();

  // scrubbing
  let dragging = false;
  const ratioAt = (e) => {
    const r = el.bar.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
  };
  el.bar.addEventListener("pointerdown", (e) => {
    dragging = true;
    el.bar.setPointerCapture(e.pointerId);
    const r = ratioAt(e);
    el.fill.style.width = `${r * 100}%`;
    el.cur.textContent = fmt(r * S.Player.getDuration());
  });
  el.bar.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const r = ratioAt(e);
    el.fill.style.width = `${r * 100}%`;
    el.cur.textContent = fmt(r * S.Player.getDuration());
  });
  el.bar.addEventListener("pointerup", (e) => {
    if (!dragging) return;
    dragging = false;
    S.Player.seek(Math.floor(ratioAt(e) * S.Player.getDuration()));
    if (!hovering) setOpen(false);
  });

  /* ---------------------------------------------------------------- events */
  S.Player.addEventListener("songchange", () => {
    renderTrack();
    renderProgress();
    peek();
    pulse();
    setTimeout(renderUpNext, 800); // queue updates slightly after songchange
  });
  S.Player.addEventListener("onplaypause", renderState);
  S.Player.addEventListener("onprogress", renderProgress);
  setInterval(() => {
    renderProgress();
    if (root.classList.contains("np-open")) renderState();
  }, 1000);

  /* ---------------------------------------------------------------- settings menu */
  function settingsModal() {
    const wrap = document.createElement("div");
    wrap.style.cssText = "display:flex;flex-direction:column;gap:14px;padding:4px 0";
    const row = (label, control) => {
      const r = document.createElement("label");
      r.style.cssText = "display:flex;justify-content:space-between;align-items:center;gap:16px;cursor:pointer";
      const t = document.createElement("span");
      t.textContent = label;
      r.append(t, control);
      wrap.appendChild(r);
    };
    const toggle = (key, label) => {
      const c = document.createElement("input");
      c.type = "checkbox";
      c.checked = !!cfg[key];
      c.style.cssText = "width:18px;height:18px;accent-color:#1ed760";
      c.onchange = () => {
        cfg[key] = c.checked;
        save();
        applySettings();
      };
      row(label, c);
    };
    toggle("enabled", "Show Notch Player");
    const sel = document.createElement("select");
    sel.style.cssText = "background:#222;color:#fff;border:1px solid #444;border-radius:6px;padding:4px 8px";
    for (const [v, t] of [
      ["center", "Center"],
      ["left", "Left"],
      ["right", "Right"],
    ]) {
      const o = document.createElement("option");
      o.value = v;
      o.textContent = t;
      o.selected = cfg.position === v;
      sel.appendChild(o);
    }
    sel.onchange = () => {
      cfg.position = sel.value;
      save();
      applySettings();
    };
    row("Position", sel);
    toggle("expandOnSongChange", "Expand briefly on song change");
    toggle("showVisualizer", "Show visualizer bars");
    toggle("showUpNext", "Show 'Up next'");
    toggle("tintFromArt", "Tint accent from album art");
    toggle("hideNativeBar", "Hide Spotify's bottom player bar");
    S.PopupModal.display({ title: "Notch Player", content: wrap, isLarge: false });
  }

  if (S.Menu?.Item) {
    new S.Menu.Item("Notch Player", false, settingsModal).register();
  }
  if (S.Keyboard?.registerShortcut) {
    try {
      S.Keyboard.registerShortcut({ key: "n", ctrl: true, alt: true }, () => {
        cfg.enabled = !cfg.enabled;
        save();
        applySettings();
      });
    } catch (_) {}
  }

  /* ---------------------------------------------------------------- native notch bridge
   * The companion "Notch Player" macOS app draws the player inside the physical notch,
   * on top of every app. It listens on ws://127.0.0.1:47823; we stream state to it and
   * run the commands it sends back. While it's connected the in-window pill is hidden. */
  const BRIDGE_URL = "ws://127.0.0.1:47823";
  let ws = null;
  let lyricsFor = "";
  let lyrics = null;

  async function fetchLyrics(uri) {
    lyricsFor = uri;
    lyrics = null;
    const id = uri?.split(":")[2];
    if (!id || !uri.startsWith("spotify:track:")) return;
    try {
      const r = await S.CosmosAsync.get(
        `https://spclient.wg.spotify.com/color-lyrics/v2/track/${id}?format=json&vocalRemoval=false&market=from_token`
      );
      if (lyricsFor !== uri) return;
      const l = r?.lyrics;
      if (l?.syncType === "LINE_SYNCED" && Array.isArray(l.lines)) {
        lyrics = l.lines.map((x) => ({ t: +x.startTimeMs || 0, w: x.words || "" }));
        pushState();
      }
    } catch (_) {}
  }

  /* ---------------------------------------------------------------- beat-synced visualizer */
  // Compact Spotify audio analysis: segs [startMs, durMs, loudStart, loudMax, loudMaxTimeMs, band0..band3], beats [startMs].
  let viz = null;
  let vizFor = null;
  let vizSentFor = null;
  async function fetchViz(uri) {
    vizFor = uri;
    viz = null;
    if (!uri?.startsWith("spotify:track:") || !S.getAudioData) return;
    try {
      const d = await S.getAudioData(uri);
      if (vizFor !== uri || !d?.segments?.length) return;
      viz = {
        uri,
        segs: d.segments.map((g) => [
          Math.round(g.start * 1000),
          Math.round(g.duration * 1000),
          +(+g.loudness_start || -60).toFixed(1),
          +(+g.loudness_max || -60).toFixed(1),
          Math.round((g.loudness_max_time || 0) * 1000),
          ...[0, 3, 6, 9].map((k) => +Math.max(...(g.pitches || [0.5]).slice(k, k + 3), 0).toFixed(2)),
        ]),
        beats: (d.beats || []).map((b) => Math.round(b.start * 1000)),
      };
      pushState();
    } catch (_) {}
  }
  const lastIdx = (n, at, pos) => {
    let lo = 0, hi = n - 1;
    if (hi < 0 || at(0) > pos) return -1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (at(mid) <= pos) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  };
  // Same envelope as the native app's Viz.levels(at:).
  function vizLevels(pos) {
    const segs = viz.segs;
    const i = Math.max(0, lastIdx(segs.length, (k) => segs[k][0], pos));
    const g = segs[i];
    const local = Math.max(0, pos - g[0]), peak = Math.max(1, g[4]), dur = Math.max(peak + 1, g[1]);
    const next = i + 1 < segs.length ? segs[i + 1][2] : -60;
    const loud = local < peak ? g[2] + ((g[3] - g[2]) * local) / peak : g[3] + (next - g[3]) * Math.min(1, (local - peak) / (dur - peak));
    const level = Math.pow(Math.min(1, Math.max(0, (loud + 35) / 30)), 1.3);
    const b = lastIdx(viz.beats.length, (k) => viz.beats[k], pos);
    const pulse = b >= 0 ? Math.exp(-(pos - viz.beats[b]) / 150) : 0;
    return [0, 1, 2, 3].map((k) => Math.min(1, 0.12 + 0.88 * level * (0.55 + 0.45 * g[5 + k]) * (0.6 + 0.6 * pulse)));
  }
  const vizBars = [...root.querySelectorAll(".np-viz")].map((v) => [...v.querySelectorAll("i")]);
  (function vizLoop() {
    requestAnimationFrame(vizLoop);
    const live =
      viz && viz.uri === current.uri && !bridged && cfg.enabled && cfg.showVisualizer && safe(() => S.Player.isPlaying(), false);
    if (!live) {
      if (root.classList.contains("np-live")) {
        root.classList.remove("np-live");
        vizBars.flat().forEach((b) => (b.style.height = ""));
      }
      return;
    }
    root.classList.add("np-live");
    const lv = vizLevels(safe(() => S.Player.getProgress(), 0));
    vizBars.forEach((bars) => bars.forEach((b, k) => (b.style.height = `${(lv[k] * 100).toFixed(1)}%`)));
  })();

  function snapshot() {
    const item = S.Player.data?.item;
    if (!item) return null;
    const m = item.metadata || {};
    const nt = safe(() => S.Queue?.nextTracks?.[0]?.contextTrack?.metadata, null);
    return {
      uri: item.uri || "",
      title: m.title || item.name || "",
      artist: m.artist_name || (item.artists || []).map((a) => a.name).join(", ") || "",
      album: m.album_title || item.album?.name || "",
      art: img(m.image_xlarge_url || m.image_large_url || m.image_url || item.album?.images?.[0]?.url) || null,
      albumUri: m.album_uri || item.album?.uri || null,
      artistUri: m.artist_uri || item.artists?.[0]?.uri || null,
      duration: safe(() => S.Player.getDuration(), 0),
      position: safe(() => S.Player.getProgress(), 0),
      ts: Date.now(),
      playing: !!safe(() => S.Player.isPlaying(), false),
      shuffle: !!safe(() => S.Player.getShuffle(), false),
      repeatMode: safe(() => S.Player.getRepeat(), 0) || 0,
      liked: !!safe(() => S.Player.getHeart(), false),
      volume: safe(() => S.Player.getVolume(), 1),
      device: safe(() => S.Platform.ConnectAPI?.state?.activeDevice?.name, "") || "",
      next: nt?.title
        ? { title: nt.title, artist: nt.artist_name || "", art: img(nt.image_url || nt.image_large_url || nt.image_small_url) || null }
        : null,
      lyrics: lyricsFor === item.uri ? lyrics : null,
      // the analysis is large, so it is sent once per track (the app keeps it until the song changes)
      viz: viz && viz.uri === item.uri && vizSentFor !== item.uri ? viz : null,
    };
  }

  let pushTimer = null;
  function pushState() {
    // coalesce bursts of events into one message
    if (pushTimer) return;
    pushTimer = setTimeout(() => {
      pushTimer = null;
      if (!ws || ws.readyState !== 1) return;
      const s = snapshot();
      if (!s) return;
      ws.send(JSON.stringify(s));
      if (s.viz) vizSentFor = s.uri;
    }, 60);
  }

  function runCommand(c) {
    switch (c.cmd) {
      case "toggle": S.Player.togglePlay(); break;
      case "next": S.Player.next(); break;
      case "prev": S.Player.back(); break;
      case "seek": S.Player.seek(Math.floor(c.ms)); break;
      case "shuffle": S.Player.toggleShuffle(); break;
      case "repeat": S.Player.toggleRepeat(); break;
      case "like": S.Player.toggleHeart(); break;
      case "volume": S.Player.setVolume(Math.max(0, Math.min(1, +c.v))); break;
      case "open":
        if (c.uri === "queue") S.Platform.History.push("/queue");
        else go(c.uri);
        break;
    }
    setTimeout(pushState, 250);
  }

  function setBridged(on) {
    bridged = on;
    root.classList.toggle("np-bridged", on);
  }

  function connectBridge() {
    try {
      ws = new WebSocket(BRIDGE_URL);
    } catch (_) {
      return setTimeout(connectBridge, 5000);
    }
    ws.onopen = () => {
      vizSentFor = null; // a (re)started app needs the analysis again
      setBridged(true);
      pushState();
    };
    ws.onmessage = (e) => {
      try {
        runCommand(JSON.parse(e.data));
      } catch (_) {}
    };
    ws.onclose = () => {
      setBridged(false);
      ws = null;
      setTimeout(connectBridge, 4000);
    };
    ws.onerror = () => {};
  }
  style.textContent += `#np-root.np-bridged{display:none!important}`;

  S.Player.addEventListener("songchange", () => {
    fetchLyrics(S.Player.data?.item?.uri);
    fetchViz(S.Player.data?.item?.uri);
    pushState();
    setTimeout(pushState, 900);
  });
  S.Player.addEventListener("onplaypause", pushState);
  // Resync every few seconds (catches seeks, likes, volume and queue changes made elsewhere).
  setInterval(pushState, 3000);
  connectBridge();
  fetchLyrics(S.Player.data?.item?.uri);
  fetchViz(S.Player.data?.item?.uri);

  applySettings();
  renderTrack();
  renderProgress();
})();
