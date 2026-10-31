(() => {
  const player = document.querySelector('.video-demo');
  const video = player.querySelector('video');
  const controls = player.querySelector('.demo-controls');
  const toggle = player.querySelector('.video-toggle');
  const replay = player.querySelector('.video-replay');
  const scrubber = player.querySelector('.demo-scrub');
  const clock = player.querySelector('.demo-clock');
  const chapterList = player.querySelector('.chapter-list');
  const chapters = [...player.querySelectorAll('.demo-chapter')].map(button => ({
    button,
    start: Number(button.dataset.start),
    label: button.textContent.trim(),
  }));
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let duration = Number(scrubber.max);
  let animationFrame = 0;
  let scrubbing = false;
  let resumeAfterScrub = false;

  const formatTime = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
  const canSeek = () => Number.isFinite(video.duration) && video.duration > 0;
  const chapterEnd = index => chapters[index + 1]?.start ?? duration;

  function sync() {
    const time = Math.max(0, Math.min(duration, video.currentTime));
    let current = chapters[0];
    chapters.forEach((chapter, index) => {
      const end = chapterEnd(index);
      const progress = Math.max(0, Math.min(1, (time - chapter.start) / (end - chapter.start)));
      chapter.button.style.setProperty('--progress', progress);
      chapter.button.disabled = !canSeek();
      if (time >= chapter.start && (time < end || index === chapters.length - 1)) {
        current = chapter;
        chapter.button.setAttribute('aria-current', 'step');
      } else {
        chapter.button.removeAttribute('aria-current');
      }
    });
    if (!scrubbing) scrubber.value = time;
    scrubber.disabled = !canSeek();
    scrubber.setAttribute('aria-valuetext', `${formatTime(time)} of ${formatTime(Math.ceil(duration))}, ${current.label}`);
    clock.textContent = `${formatTime(time)} / ${formatTime(Math.ceil(duration))}`;
    toggle.textContent = video.paused ? 'Play' : 'Pause';
    toggle.setAttribute('aria-label', `${video.paused ? 'Play' : 'Pause'} demo`);
  }

  function metadataLoaded() {
    if (!canSeek()) return;
    duration = video.duration;
    scrubber.max = duration;
    chapterList.style.setProperty('--chapter-tracks', chapters.map((chapter, index) => `minmax(44px, ${chapterEnd(index) - chapter.start}fr)`).join(' '));
    chapters.forEach(chapter => chapter.button.setAttribute('aria-label', `${chapter.label}, jump to ${formatTime(chapter.start)}`));
    sync();
  }

  function seek(time) {
    if (!canSeek()) return;
    video.currentTime = Math.max(0, Math.min(duration - 0.01, time));
    sync();
  }

  function play() {
    video.play().catch(sync);
  }

  function tick() {
    sync();
    if (!video.paused) animationFrame = requestAnimationFrame(tick);
  }

  chapters.forEach(chapter => chapter.button.addEventListener('click', () => seek(chapter.start)));
  toggle.addEventListener('click', () => video.paused ? play() : video.pause());
  replay.addEventListener('click', () => {
    seek(0);
    play();
  });

  scrubber.addEventListener('pointerdown', event => {
    scrubbing = true;
    resumeAfterScrub = !video.paused;
    video.pause();
    scrubber.setPointerCapture(event.pointerId);
  });
  scrubber.addEventListener('input', () => seek(Number(scrubber.value)));
  function finishScrub() {
    if (!scrubbing) return;
    scrubbing = false;
    if (resumeAfterScrub) play();
    sync();
  }
  scrubber.addEventListener('pointerup', finishScrub);
  scrubber.addEventListener('pointercancel', finishScrub);
  scrubber.addEventListener('lostpointercapture', finishScrub);
  scrubber.addEventListener('blur', finishScrub);

  video.addEventListener('loadedmetadata', metadataLoaded);
  video.addEventListener('durationchange', metadataLoaded);
  video.addEventListener('timeupdate', sync);
  video.addEventListener('seeked', sync);
  video.addEventListener('play', () => {
    cancelAnimationFrame(animationFrame);
    tick();
  });
  video.addEventListener('pause', () => {
    cancelAnimationFrame(animationFrame);
    sync();
  });
  video.addEventListener('error', () => {
    cancelAnimationFrame(animationFrame);
    controls.hidden = true;
    video.controls = true;
    player.querySelector('.demo-fallback').hidden = false;
  });
  reducedMotion.addEventListener('change', event => {
    if (event.matches) video.pause();
  });

  video.controls = false;
  controls.hidden = false;
  metadataLoaded();
  sync();
  if (!reducedMotion.matches) play();
})();
