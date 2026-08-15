/* PinSnap 官网 v2 — 入场序列 + 滚动显现 + 贴图视差 */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* 1. Hero 标题逐行入场 */
  var titleLines = document.querySelectorAll(".hero-title .t-line");
  if (titleLines.length && !reduceMotion) {
    titleLines.forEach(function (line, i) {
      line.style.animation =
        "rise .8s cubic-bezier(.2,.7,.2,1) " + (0.15 + i * 0.18) + "s both";
    });
    var sub = document.querySelector(".hero-sub");
    if (sub) sub.style.animation = "rise .8s cubic-bezier(.2,.7,.2,1) .55s both";
    var cta = document.querySelector(".hero-cta");
    if (cta) cta.style.animation = "rise .8s cubic-bezier(.2,.7,.2,1) .7s both";
    var note = document.querySelector(".hero-note");
    if (note) note.style.animation = "rise .8s cubic-bezier(.2,.7,.2,1) .85s both";
  }

  /* 2. 滚动显现 */
  var revealEls = document.querySelectorAll(
    ".section-head, .feat-card, .price-card, .download-box, .shortcuts-copy"
  );

  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
    );
    revealEls.forEach(function (el, i) {
      el.classList.add("reveal");
      el.style.setProperty("--d", (i % 6) * 0.06 + "s");
      io.observe(el);
    });
  } else {
    revealEls.forEach(function (el) {
      el.classList.add("in");
    });
  }

  /* 3. 贴图堆鼠标视差 */
  var stage = document.querySelector(".hero-stage");
  var pinStack = document.querySelector(".pin-stack");
  if (stage && pinStack && !reduceMotion && window.matchMedia("(pointer: fine)").matches) {
    var rafId = null;
    var tx = 0, ty = 0;
    stage.addEventListener("mousemove", function (e) {
      var r = stage.getBoundingClientRect();
      tx = (e.clientX - (r.left + r.width / 2)) / r.width;
      ty = (e.clientY - (r.top + r.height / 2)) / r.height;
      if (rafId) return;
      rafId = requestAnimationFrame(function () {
        pinStack.style.transform =
          "translate3d(" + tx * 10 + "px, " + ty * 8 + "px, 0)";
        rafId = null;
      });
    });
    stage.addEventListener("mouseleave", function () {
      pinStack.style.transition = "transform .8s cubic-bezier(.2,.7,.2,1)";
      pinStack.style.transform = "translate3d(0,0,0)";
      setTimeout(function () {
        pinStack.style.transition = "";
      }, 800);
    });
  }

  /* 4. 导航栏滚动后阴影 */
  var nav = document.querySelector(".nav");
  var onScroll = function () {
    if (!nav) return;
    if (window.scrollY > 8) {
      nav.style.boxShadow = "0 6px 24px rgb(0 0 0 / .35)";
    } else {
      nav.style.boxShadow = "none";
    }
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();
})();
