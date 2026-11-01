(() => {
  const player = document.querySelector('.video-demo');
  const video = player.querySelector('video');
  const starter = player.querySelector('.demo-start');
  if (!starter) return;
  const controls = player.querySelector('.demo-controls');
  const toggle = player.querySelector('.video-toggle');
  const replay = player.querySelector('.video-replay');
  const sound = player.querySelector('.video-sound');
  const scrubber = player.querySelector('.demo-scrub');
  const clock = player.querySelector('.demo-clock');
  const chapterList = player.querySelector('.chapter-list');
  const timeline = player.querySelector('.chapter-timeline');
  const chapters = [...player.querySelectorAll('.demo-chapter')].map(button => ({
    button,
    start: Number(button.dataset.start),
    track: button.querySelector('.chapter-track'),
    label: button.textContent.trim(),
  }));
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let duration = Number(scrubber.max);
  let animationFrame = 0;
  let scrubbing = false;
  let resumeAfterScrub = false;
  let trackBounds = [];

  const formatTime = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
  const canSeek = () => Number.isFinite(video.duration) && video.duration > 0;
  const chapterEnd = index => chapters[index + 1]?.start ?? duration;

  function sync() {
    const time = Math.max(0, Math.min(duration, video.currentTime));
    let current = chapters[0];
    let currentIndex = 0;
    let currentProgress = 0;
    chapters.forEach((chapter, index) => {
      const end = chapterEnd(index);
      const progress = Math.max(0, Math.min(1, (time - chapter.start) / (end - chapter.start)));
      chapter.button.style.setProperty('--progress', progress);
      chapter.button.disabled = !canSeek();
      if (time >= chapter.start && (time < end || index === chapters.length - 1)) {
        current = chapter;
        currentIndex = index;
        currentProgress = progress;
        chapter.button.setAttribute('aria-current', 'step');
      } else {
        chapter.button.removeAttribute('aria-current');
      }
    });
    const track = trackBounds[currentIndex];
    if (track) {
      timeline.style.setProperty('--playhead-x', `${track.left + track.width * currentProgress}px`);
      timeline.style.setProperty('--playhead-y', `${track.centerY}px`);
    }
    if (!scrubbing) scrubber.value = time;
    scrubber.disabled = !canSeek();
    scrubber.setAttribute('aria-valuetext', `${formatTime(time)} of ${formatTime(Math.ceil(duration))}, ${current.label}`);
    clock.textContent = `${formatTime(time)} / ${formatTime(Math.ceil(duration))}`;
    toggle.textContent = video.paused ? 'Play' : 'Pause';
    toggle.setAttribute('aria-label', `${video.paused ? 'Play' : 'Pause'} demo`);
    sound.setAttribute('aria-pressed', String(!video.muted));
    const soundAction = video.muted ? 'Unmute demo' : 'Mute demo';
    sound.setAttribute('aria-label', soundAction);
    sound.title = soundAction;
  }

  function measureTracks() {
    const parent = timeline.getBoundingClientRect();
    trackBounds = chapters.map(chapter => {
      const rect = chapter.track.getBoundingClientRect();
      return { left: rect.left - parent.left, width: rect.width, centerY: rect.top + rect.height / 2 - parent.top };
    });
  }

  function metadataLoaded() {
    if (!canSeek()) return;
    duration = video.duration;
    scrubber.max = duration;
    chapterList.style.setProperty('--chapter-tracks', chapters.map((chapter, index) => `minmax(44px, ${chapterEnd(index) - chapter.start}fr)`).join(' '));
    measureTracks();
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
  starter.addEventListener('click', play);
  toggle.addEventListener('click', () => video.paused ? play() : video.pause());
  sound.addEventListener('click', () => {
    video.muted = !video.muted;
  });
  replay.addEventListener('click', () => {
    seek(0);
    play();
  });

  function seekFromPointer(event) {
    const x = event.clientX - timeline.getBoundingClientRect().left;
    let time = duration;
    for (let index = 0; index < chapters.length; index++) {
      const track = trackBounds[index];
      if (x <= track.left + track.width) {
        const progress = Math.max(0, Math.min(1, (x - track.left) / track.width));
        time = chapters[index].start + progress * (chapterEnd(index) - chapters[index].start);
        break;
      }
    }
    scrubber.value = time;
    seek(time);
  }

  scrubber.addEventListener('pointerdown', event => {
    event.preventDefault();
    scrubber.focus({ preventScroll: true });
    scrubbing = true;
    resumeAfterScrub = !video.paused;
    video.pause();
    scrubber.setPointerCapture(event.pointerId);
    seekFromPointer(event);
  });
  scrubber.addEventListener('pointermove', event => {
    if (scrubbing) seekFromPointer(event);
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
  video.addEventListener('volumechange', sync);
  video.addEventListener('playing', () => {
    const moveFocus = document.activeElement === starter;
    starter.hidden = true;
    player.classList.remove('is-awaiting-play');
    controls.hidden = false;
    measureTracks();
    sync();
    if (moveFocus) toggle.focus({ preventScroll: true });
  }, { once: true });
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
    starter.hidden = true;
    controls.hidden = true;
    player.classList.remove('is-awaiting-play');
    video.controls = true;
    player.querySelector('.demo-fallback').hidden = false;
  });
  reducedMotion.addEventListener('change', event => {
    if (event.matches) video.pause();
  });

  new ResizeObserver(() => {
    measureTracks();
    sync();
  }).observe(chapterList);

  video.controls = false;
  starter.hidden = false;
  player.classList.add('is-awaiting-play');
  metadataLoaded();
  sync();
})();
