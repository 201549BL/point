(() => {
  'use strict';

  const tools = [
    { id: 'arrow', label: 'Arrow', key: 'A', icon: 'arrow-up-right' },
    { id: 'blur', label: 'Blur', key: 'B', icon: 'square-grid-3x3-fill' },
    { id: 'redaction', label: 'Redaction', key: 'R', icon: 'rectangle-fill' },
  ];
  const state = {
    phase: 'idle', tool: 'arrow', annotations: [], selectedID: null,
    gesture: null, clickGuard: null, undo: [], redo: [], source: null, editor: null, generation: 0,
  };
  const interactiveSelector = 'a, button, input, select, textarea, video, audio, summary, label, [contenteditable]:not([contenteditable="false"]), [role="button"], [role="slider"]';
  const svgNS = 'http://www.w3.org/2000/svg';
  const clone = value => JSON.parse(JSON.stringify(value));
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  const mosaicCache = new Map();
  let pausedVideos = [];
  const hitContext = document.createElement('canvas').getContext('2d');

  const activate = document.createElement('button');
  activate.type = 'button';
  activate.className = 'point-annotate-launch';
  activate.append(icon('pencil', 'svg'), document.createTextNode('Try annotating'));
  activate.setAttribute('aria-expanded', 'false');
  activate.setAttribute('aria-controls', 'point-annotation-toolbar');
  const invitation = document.createElement('div');
  invitation.className = 'point-annotation-invitation';
  const invitationHint = document.createElement('p');
  invitationHint.textContent = "A little playground for Point's annotation tools.";
  invitation.append(activate, invitationHint);

  const overlay = document.createElement('div');
  overlay.className = 'point-annotation-overlay';
  overlay.hidden = true;
  const surface = document.createElement('div');
  surface.className = 'point-annotation-surface';
  surface.setAttribute('aria-label', 'Annotation canvas. Drag to draw; click an annotation to select it.');
  const concealments = document.createElement('div');
  concealments.className = 'point-annotation-concealments';
  const arrows = document.createElementNS(svgNS, 'svg');
  arrows.classList.add('point-annotation-arrows');
  arrows.setAttribute('aria-hidden', 'true');
  const captions = document.createElement('div');
  captions.className = 'point-annotation-captions';
  overlay.append(surface, concealments, arrows, captions);
  const captionMeasure = document.createElement('div');
  captionMeasure.className = 'point-annotation-caption';
  captionMeasure.setAttribute('aria-hidden', 'true');
  Object.assign(captionMeasure.style, { position: 'fixed', left: '-10000px', top: '0', visibility: 'hidden', minHeight: '30px' });

  const toolbar = document.createElement('div');
  toolbar.id = 'point-annotation-toolbar';
  toolbar.className = 'point-annotation-toolbar';
  toolbar.setAttribute('role', 'group');
  toolbar.setAttribute('aria-label', 'Page annotation tools');
  toolbar.hidden = true;
  const toolGroup = document.createElement('div');
  toolGroup.className = 'point-annotation-tools';
  function icon(name, extension = 'png') {
    const span = document.createElement('span');
    span.className = 'point-annotation-icon';
    span.style.setProperty('--point-icon', `url("icons/${name}.${extension}")`);
    span.setAttribute('aria-hidden', 'true');
    return span;
  }
  const toolButtons = tools.map(tool => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'point-annotation-tool';
    button.dataset.tool = tool.id;
    button.title = `${tool.label} (${tool.key})`;
    button.setAttribute('aria-label', button.title);
    button.append(icon(tool.icon));
    button.addEventListener('click', () => selectTool(tool.id));
    toolGroup.append(button);
    return button;
  });
  const actions = document.createElement('div');
  actions.className = 'point-annotation-actions';
  function action(label, run, image) {
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.action = label.toLowerCase();
    button.title = label;
    button.setAttribute('aria-label', label);
    if (image) button.append(icon(image));
    else button.textContent = label;
    button.addEventListener('click', run);
    actions.append(button);
    return button;
  }
  const undo = action('Undo', () => travelHistory('undo'), 'arrow-uturn-backward');
  undo.title = 'Undo (⌘Z / Ctrl+Z)';
  const redo = action('Redo', () => travelHistory('redo'), 'arrow-uturn-forward');
  redo.title = 'Redo (⇧⌘Z / Ctrl+Shift+Z)';
  const remove = action('Delete', deleteSelection);
  const clear = action('Clear all', () => {
    finishCaption();
    cancelGesture();
    const before = clone(state.annotations);
    state.annotations = [];
    state.selectedID = null;
    checkpoint(before);
    render();
  });
  clear.className = 'point-annotation-clear';
  clear.title = 'Remove all annotations';
  toolbar.append(toolGroup, actions);
  const dock = document.createElement('div');
  dock.className = 'point-annotation-dock';
  dock.hidden = true;
  dock.append(toolbar);
  const status = document.createElement('div');
  status.className = 'point-annotation-status';
  status.setAttribute('role', 'status');
  status.hidden = true;
  for (const element of [overlay, dock, status, captionMeasure]) element.setAttribute('data-html2canvas-ignore', 'true');
  const heroActions = document.querySelector('.hero .actions');
  if (heroActions) heroActions.after(invitation);
  else document.body.append(invitation);
  document.body.append(overlay, dock, status, captionMeasure);

  let statusTimeout;
  function announce(message) {
    clearTimeout(statusTimeout);
    status.textContent = message;
    status.hidden = !message;
    if (message && state.phase === 'idle') statusTimeout = setTimeout(() => announce(''), 7000);
  }

  function selectTool(id) {
    finishCaption();
    cancelGesture();
    state.tool = id;
    toolButtons.forEach((button, index) => button.setAttribute('aria-pressed', String(tools[index].id === id)));
  }

  async function captureSource(generation) {
    overlay.classList.add('point-annotation-capturing');
    try {
      while (generation === state.generation) {
        const width = window.innerWidth;
        const height = window.innerHeight;
        const source = await window.PointMosaic.capture();
        if (generation !== state.generation) return null;
        if (width === window.innerWidth && height === window.innerHeight) return source;
      }
      return null;
    } finally {
      if (generation === state.generation) overlay.classList.remove('point-annotation-capturing');
    }
  }

  async function setActive(active) {
    finishCaption(!active);
    cancelGesture();
    const generation = ++state.generation;
    if (!active) {
      state.phase = 'idle';
      document.removeEventListener('touchmove', preventDrawingScroll, true);
      document.documentElement.classList.remove('point-annotation-active', 'point-annotation-hover');
      overlay.classList.remove('point-annotation-capturing');
      state.annotations = [];
      state.selectedID = null;
      state.undo = [];
      state.redo = [];
      state.source = null;
      mosaicCache.clear();
      concealments.replaceChildren();
      arrows.replaceChildren();
      captions.replaceChildren();
      overlay.hidden = toolbar.hidden = dock.hidden = true;
      activate.disabled = false;
      activate.setAttribute('aria-expanded', 'false');
      announce('');
      for (const video of pausedVideos) video.play()?.catch(() => {});
      pausedVideos = [];
      activate.focus({ preventScroll: true });
      return;
    }
    state.phase = 'loading';
    activate.disabled = true;
    toolbar.hidden = dock.hidden = false;
    activate.setAttribute('aria-expanded', 'true');
    pausedVideos = [...document.querySelectorAll('video')].filter(video => !video.paused && !video.ended);
    pausedVideos.forEach(video => video.pause());
    render();
    try {
      if (!window.PointMosaic) throw new Error('The page capture tool is unavailable.');
      const source = await captureSource(generation);
      if (generation !== state.generation) return;
      state.source = source;
      fitAnnotations();
      mosaicCache.clear();
      state.phase = 'active';
      document.addEventListener('touchmove', preventDrawingScroll, { capture: true, passive: false });
      document.documentElement.classList.add('point-annotation-active');
      overlay.hidden = false;
      arrows.setAttribute('width', source.width);
      arrows.setAttribute('height', source.height);
      render();
      announce('');
      toolButtons[tools.findIndex(tool => tool.id === state.tool)].focus({ preventScroll: true });
    } catch (error) {
      if (generation !== state.generation) return;
      setActive(false);
      announce('The page could not be captured. Choose “Try annotating” to retry.');
      console.error('Point annotation capture failed', error);
    }
  }

  function checkpoint(before) {
    if (JSON.stringify(before) === JSON.stringify(state.annotations)) return;
    state.undo.push(before);
    if (state.undo.length > 100) state.undo.shift();
    state.redo = [];
  }

  function travelHistory(direction) {
    finishCaption();
    cancelGesture();
    const previous = state[direction].pop();
    if (!previous) return;
    state[direction === 'undo' ? 'redo' : 'undo'].push(clone(state.annotations));
    state.annotations = previous;
    fitAnnotations();
    if (!selected()) state.selectedID = null;
    render();
  }

  function selected() {
    return state.annotations.find(annotation => annotation.id === state.selectedID);
  }

  function deleteSelection() {
    finishCaption();
    cancelGesture();
    if (!selected()) return;
    const before = clone(state.annotations);
    state.annotations = state.annotations.filter(annotation => annotation.id !== state.selectedID);
    state.selectedID = null;
    checkpoint(before);
    render();
  }

  function cancelGesture() {
    const gesture = state.gesture;
    if (!gesture) return;
    state.gesture = null;
    document.documentElement.classList.remove('point-annotation-dragging');
    state.annotations = gesture.before;
    if (surface.hasPointerCapture(gesture.pointerId)) surface.releasePointerCapture(gesture.pointerId);
    render();
  }

  function point(event) {
    return { x: clamp(event.pageX, 0, state.source.width), y: clamp(event.pageY, 0, state.source.height) };
  }

  function rectangle(a, b) {
    return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) };
  }

  function corners(rect) {
    return [
      { x: rect.x, y: rect.y }, { x: rect.x + rect.width, y: rect.y },
      { x: rect.x, y: rect.y + rect.height }, { x: rect.x + rect.width, y: rect.y + rect.height },
    ];
  }

  function curve(arrow) {
    const dx = arrow.head.x - arrow.tail.x;
    const dy = arrow.head.y - arrow.tail.y;
    const position = arrow.bendPosition;
    const handle = { x: arrow.tail.x + position * dx - arrow.bend * dy, y: arrow.tail.y + position * dy + arrow.bend * dx };
    const t = Math.sqrt(position) / (Math.sqrt(position) + Math.sqrt(1 - position));
    const offset = arrow.bend / (2 * t * (1 - t));
    const control = arrow.bend === 0 ? arrow.tail : {
      x: arrow.tail.x + position * dx - offset * dy,
      y: arrow.tail.y + position * dy + offset * dx,
    };
    const shaft = `M ${arrow.tail.x} ${arrow.tail.y} ${arrow.bend === 0 ? 'L' : `Q ${control.x} ${control.y}`} ${arrow.head.x} ${arrow.head.y}`;
    return { control, handle, shaft };
  }

  function bounds(annotation) {
    if (annotation.tool !== 'arrow') return annotation.rect;
    const { tail, head } = annotation;
    const { control } = curve(annotation);
    const points = [tail, head];
    if (annotation.bend !== 0) {
      for (const axis of ['x', 'y']) {
        const t = (tail[axis] - control[axis]) / (tail[axis] - 2 * control[axis] + head[axis]);
        if (t > 0 && t < 1) points.push({
          x: (1 - t) ** 2 * tail.x + 2 * (1 - t) * t * control.x + t ** 2 * head.x,
          y: (1 - t) ** 2 * tail.y + 2 * (1 - t) * t * control.y + t ** 2 * head.y,
        });
      }
    }
    const xs = points.map(p => p.x);
    const ys = points.map(p => p.y);
    return { x: Math.min(...xs), y: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys) };
  }

  function constrainBend(arrow) {
    const length = distance(arrow.tail, arrow.head);
    if (length < .001) { arrow.bend = 0; return; }
    const padding = Math.min(.45, Math.max(.08, 16 / length));
    arrow.bendPosition = clamp(arrow.bendPosition, padding, 1 - padding);
    const requested = arrow.bend;
    const fits = () => {
      const rect = bounds(arrow);
      return rect.x >= -.0001 && rect.y >= -.0001 && rect.x + rect.width <= state.source.width + .0001 && rect.y + rect.height <= state.source.height + .0001;
    };
    if (fits()) return;
    let low = 0;
    let high = 1;
    for (let i = 0; i < 32; i++) {
      const fraction = (low + high) / 2;
      arrow.bend = requested * fraction;
      if (fits()) low = fraction; else high = fraction;
    }
    arrow.bend = requested * low;
  }

  function fitAnnotations() {
    const { width, height } = state.source;
    for (const annotation of state.annotations) {
      if (annotation.tool === 'arrow') {
        const original = bounds(annotation);
        const scale = Math.min(1, width / Math.max(original.width, .001), height / Math.max(original.height, .001));
        for (const endpoint of [annotation.tail, annotation.head]) {
          endpoint.x = original.x + (endpoint.x - original.x) * scale;
          endpoint.y = original.y + (endpoint.y - original.y) * scale;
        }
        const rect = bounds(annotation);
        const dx = clamp(0, -rect.x, width - rect.x - rect.width);
        const dy = clamp(0, -rect.y, height - rect.y - rect.height);
        for (const endpoint of [annotation.tail, annotation.head]) {
          endpoint.x += dx;
          endpoint.y += dy;
        }
        constrainBend(annotation);
      } else {
        const rect = annotation.rect;
        rect.width = Math.min(rect.width, width);
        rect.height = Math.min(rect.height, height);
        rect.x = clamp(rect.x, 0, width - rect.width);
        rect.y = clamp(rect.y, 0, height - rect.height);
      }
    }
  }

  function captionFrame(arrow, text = arrow.caption) {
    hitContext.font = '600 15px -apple-system, BlinkMacSystemFont, sans-serif';
    const width = Math.min(Math.min(420, state.source.width * .72), Math.max(64, hitContext.measureText(text || 'Caption').width + 20));
    captionMeasure.style.width = `${width}px`;
    captionMeasure.textContent = text || 'Caption';
    const height = captionMeasure.getBoundingClientRect().height;
    let x = arrow.tail.x + 12;
    let y = arrow.tail.y + 12;
    if (x + width > state.source.width - 6) x = arrow.tail.x - width - 12;
    if (y + height > state.source.height - 6) y = arrow.tail.y - height - 12;
    return { x: clamp(x, 6, state.source.width - width - 6), y: clamp(y, 6, state.source.height - height - 6), width, height };
  }

  function contains(rect, p, padding = 0) {
    return p.x >= rect.x - padding && p.x <= rect.x + rect.width + padding && p.y >= rect.y - padding && p.y <= rect.y + rect.height + padding;
  }

  function hitAnnotation(p) {
    const reverse = [...state.annotations].reverse();
    hitContext.lineWidth = 16;
    hitContext.lineCap = 'round';
    hitContext.lineJoin = 'round';
    return reverse.find(annotation => annotation.tool === 'arrow' && (
      (annotation.caption && contains(captionFrame(annotation), p, 4)) ||
      hitContext.isPointInStroke(new Path2D(curve(annotation).shaft), p.x, p.y)
    )) || reverse.find(annotation => annotation.tool !== 'arrow' && contains(annotation.rect, p, 5));
  }

  function hitHandle(annotation, p) {
    if (!annotation) return null;
    if (annotation.tool === 'arrow') {
      if (distance(p, annotation.tail) <= 9) return { kind: 'resize', endpoint: 'tail' };
      if (distance(p, annotation.head) <= 9) return { kind: 'resize', endpoint: 'head' };
      if (distance(annotation.tail, annotation.head) >= 36 && distance(p, curve(annotation).handle) <= 10) return { kind: 'bend', snapped: annotation.bend === 0 };
    } else {
      const points = corners(annotation.rect);
      const index = points.findIndex(corner => distance(p, corner) <= 9);
      if (index !== -1) return { kind: 'resize', anchor: points[3 - index] };
    }
    return null;
  }

  function svg(name, attributes = {}, parent = arrows) {
    const element = document.createElementNS(svgNS, name);
    for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
    parent.append(element);
    return element;
  }

  function renderSelection(annotation) {
    const rect = bounds(annotation);
    const padding = annotation.tool === 'arrow' ? 14 : 4;
    svg('rect', {
      class: 'point-annotation-selection', x: rect.x - padding, y: rect.y - padding,
      width: rect.width + padding * 2, height: rect.height + padding * 2, rx: 5,
    });
    const handles = annotation.tool === 'arrow' ? [annotation.tail, annotation.head] : corners(rect);
    handles.forEach((p, index) => {
      const group = svg('g', { 'data-handle': annotation.tool === 'arrow' ? ['tail', 'head'][index] : `corner-${index}` });
      svg('circle', { cx: p.x, cy: p.y, r: 7, fill: 'rgba(0,0,0,.65)' }, group);
      svg('circle', { cx: p.x, cy: p.y, r: 5.5, fill: '#0a7aff' }, group);
      svg('circle', { cx: p.x, cy: p.y, r: 2, fill: 'white' }, group);
    });
    if (annotation.tool === 'arrow' && distance(annotation.tail, annotation.head) >= 36) {
      const p = curve(annotation).handle;
      const attributes = { x: p.x - 6, y: p.y - 6, width: 12, height: 12, transform: `rotate(45 ${p.x} ${p.y})`, 'data-handle': 'bend' };
      svg('rect', { ...attributes, fill: '#0a7aff', stroke: 'rgba(0,0,0,.75)', 'stroke-width': 4 });
      svg('rect', { ...attributes, fill: 'none', stroke: 'white', 'stroke-width': 1.5 });
    }
  }

  function render() {
    undo.disabled = state.phase !== 'active' || state.undo.length === 0;
    redo.disabled = state.phase !== 'active' || state.redo.length === 0;
    remove.disabled = state.phase !== 'active' || !selected();
    toolButtons.forEach(button => { button.disabled = state.phase !== 'active'; });
    if (state.phase !== 'active') return;
    concealments.replaceChildren();
    arrows.replaceChildren();
    captions.replaceChildren();
    const annotations = state.gesture?.draft ? [...state.annotations, state.gesture.draft] : state.annotations;
    const ids = new Set(annotations.map(annotation => annotation.id));
    for (const id of mosaicCache.keys()) if (!ids.has(id)) mosaicCache.delete(id);
    for (const annotation of annotations) {
      const attributes = { 'data-annotation-id': annotation.id, 'data-tool': annotation.tool, 'data-selected': String(annotation.id === state.selectedID) };
      if (annotation.tool === 'arrow') {
        const { control, shaft } = curve(annotation);
        const angle = Math.atan2(annotation.head.y - control.y, annotation.head.x - control.x);
        const wing = Math.PI / 7;
        const left = { x: annotation.head.x - 16 * Math.cos(angle - wing), y: annotation.head.y - 16 * Math.sin(angle - wing) };
        const right = { x: annotation.head.x - 16 * Math.cos(angle + wing), y: annotation.head.y - 16 * Math.sin(angle + wing) };
        const d = `${shaft} M ${left.x} ${left.y} L ${annotation.head.x} ${annotation.head.y} L ${right.x} ${right.y}`;
        const group = svg('g', attributes);
        svg('path', { d, class: 'point-annotation-arrow-shadow' }, group);
        svg('path', { d, class: 'point-annotation-arrow' }, group);
        svg('path', { d: shaft, class: 'point-annotation-arrow-hit' }, group);
        if (annotation.caption && state.editor?.id !== annotation.id) {
          const caption = document.createElement('div');
          caption.className = 'point-annotation-caption';
          caption.textContent = annotation.caption;
          for (const [key, value] of Object.entries(attributes)) caption.setAttribute(key, value);
          position(caption, captionFrame(annotation));
          captions.append(caption);
        }
      } else {
        let element;
        if (annotation.tool === 'blur') {
          const key = JSON.stringify(annotation.rect);
          let cached = mosaicCache.get(annotation.id);
          if (!cached || cached.key !== key) {
            const canvas = document.createElement('canvas');
            try {
              if (annotation.rect.width > 0 && annotation.rect.height > 0) window.PointMosaic.render(canvas, state.source, annotation.rect, annotation.id);
            }
            catch (error) {
              state.phase = 'idle';
              setActive(false);
              announce('The mosaic could not be rendered. Choose “Try annotating” to retry.');
              console.error('Point mosaic rendering failed', error);
              return;
            }
            cached = { key, canvas };
            mosaicCache.set(annotation.id, cached);
          }
          element = cached.canvas;
        } else element = document.createElement('div');
        element.className = `point-annotation-rectangle point-annotation-${annotation.tool}`;
        for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
        position(element, annotation.rect);
        concealments.append(element);
      }
    }
    if (selected()) renderSelection(selected());
  }

  function position(element, rect) {
    Object.assign(element.style, { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.width}px`, height: `${rect.height}px` });
  }

  function updateGesture(p) {
    const gesture = state.gesture;
    if (!gesture) return;
    if (gesture.pending && distance(gesture.start, p) < 3) return;
    gesture.pending = false;
    if (gesture.kind === 'create') {
      state.selectedID = null;
      gesture.draft = gesture.tool === 'arrow' ? {
        id: gesture.id, tool: 'arrow', tail: gesture.start, head: p, caption: '', bend: 0, bendPosition: .5,
      } : { id: gesture.id, tool: gesture.tool, rect: rectangle(gesture.start, p) };
    } else {
      const annotation = clone(gesture.original);
      if (gesture.kind === 'move') {
        const rect = bounds(annotation);
        const dx = clamp(p.x - gesture.start.x, -rect.x, state.source.width - rect.x - rect.width);
        const dy = clamp(p.y - gesture.start.y, -rect.y, state.source.height - rect.y - rect.height);
        if (annotation.tool === 'arrow') {
          for (const endpoint of ['tail', 'head']) { annotation[endpoint].x += dx; annotation[endpoint].y += dy; }
        } else { annotation.rect.x += dx; annotation.rect.y += dy; }
      } else if (gesture.kind === 'resize') {
        if (annotation.tool === 'arrow') { annotation[gesture.endpoint] = p; constrainBend(annotation); }
        else annotation.rect = rectangle(gesture.anchor, p);
      } else if (gesture.kind === 'bend') {
        const dx = annotation.head.x - annotation.tail.x;
        const dy = annotation.head.y - annotation.tail.y;
        const length = Math.hypot(dx, dy);
        if (length >= .001) {
          annotation.bendPosition = ((p.x - annotation.tail.x) * dx + (p.y - annotation.tail.y) * dy) / length ** 2;
          const offset = ((p.x - annotation.tail.x) * -dy + (p.y - annotation.tail.y) * dx) / length;
          gesture.snapped = Math.abs(offset) <= (gesture.snapped ? 8 : 5);
          annotation.bend = gesture.snapped ? 0 : offset / length;
          constrainBend(annotation);
        }
      }
      state.annotations = state.annotations.map(value => value.id === annotation.id ? annotation : value);
    }
    render();
  }

  function annotationUI(target) {
    return dock.contains(target) || invitation.contains(target) || state.editor?.element.contains(target);
  }

  function ownGesture(event) {
    const gesture = state.gesture;
    gesture.owned = true;
    state.clickGuard = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
    document.documentElement.classList.add('point-annotation-dragging');
    window.getSelection()?.removeAllRanges();
    surface.setPointerCapture(event.pointerId);
  }

  function consumePointer(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  function preventDrawingScroll(event) {
    if (state.phase === 'active' && state.gesture && event.cancelable) event.preventDefault();
  }

  document.addEventListener('pointerdown', event => {
    state.clickGuard = null;
    if (state.phase !== 'active' || state.gesture || !event.isPrimary || event.button !== 0 || annotationUI(event.target)) return;
    const p = point(event);
    const handle = hitHandle(selected(), p);
    const hit = handle ? selected() : hitAnnotation(p);
    finishCaption();
    if (!hit && event.target.closest(interactiveSelector)) return;
    if (hit) state.selectedID = hit.id;
    state.gesture = {
      ...(handle || { kind: hit ? 'move' : 'create' }), pointerId: event.pointerId,
      start: p, before: clone(state.annotations), original: hit ? clone(hit) : null,
      pending: true, owned: false, id: hit?.id || crypto.randomUUID(), tool: state.tool,
    };
    if (hit) {
      ownGesture(event);
      consumePointer(event);
    }
  }, true);
  document.addEventListener('pointermove', event => {
    const gesture = state.gesture;
    if (gesture?.pointerId === event.pointerId) {
      const p = point(event);
      if (!gesture.owned && distance(gesture.start, p) >= 3) ownGesture(event);
      if (gesture.owned) {
        state.clickGuard = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
        consumePointer(event);
        updateGesture(p);
      }
    } else if (state.phase === 'active' && event.isPrimary) {
      const p = point(event);
      const handle = !annotationUI(event.target) && hitHandle(selected(), p);
      const hit = !annotationUI(event.target) && hitAnnotation(p);
      document.documentElement.classList.toggle('point-annotation-hover', Boolean(handle || hit));
      document.documentElement.style.setProperty('--point-annotation-cursor', handle ? 'crosshair' : 'move');
    }
  }, true);
  document.addEventListener('pointerup', event => {
    if (state.gesture?.pointerId !== event.pointerId) return;
    const gesture = state.gesture;
    if (!gesture.owned && distance(gesture.start, point(event)) >= 3) ownGesture(event);
    if (gesture.owned) {
      consumePointer(event);
      updateGesture(point(event));
      if (state.phase !== 'active' || state.gesture !== gesture) return;
      state.clickGuard = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
    }
    state.gesture = null;
    document.documentElement.classList.remove('point-annotation-dragging');
    if (gesture.kind === 'create') {
      const draft = gesture.draft;
      const valid = draft && (draft.tool === 'arrow' ? distance(draft.tail, draft.head) >= 5 : draft.rect.width >= 4 && draft.rect.height >= 4);
      if (valid) { state.annotations.push(draft); state.selectedID = draft.id; }
      else state.selectedID = null;
    }
    checkpoint(gesture.before);
    if (surface.hasPointerCapture(event.pointerId)) surface.releasePointerCapture(event.pointerId);
    if (gesture.pending) requestAnimationFrame(render);
    else render();
  }, true);
  document.addEventListener('pointercancel', event => { if (state.gesture?.pointerId === event.pointerId) cancelGesture(); }, true);
  surface.addEventListener('lostpointercapture', event => { if (state.gesture?.pointerId === event.pointerId) cancelGesture(); });
  document.addEventListener('click', event => {
    const guard = state.clickGuard;
    if (!guard || event.detail === 0 || annotationUI(event.target)) return;
    state.clickGuard = null;
    if ('pointerId' in event ? event.pointerId !== guard.pointerId : Math.hypot(event.clientX - guard.x, event.clientY - guard.y) > 3) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);

  function finishCaption(cancel = false) {
    const editor = state.editor;
    if (!editor) return;
    state.editor = null;
    const annotation = state.annotations.find(value => value.id === editor.id);
    if (!cancel && annotation) {
      const before = clone(state.annotations);
      annotation.caption = editor.element.value.trim();
      checkpoint(before);
    }
    editor.element.remove();
    render();
  }

  document.addEventListener('dblclick', event => {
    if (state.phase !== 'active' || annotationUI(event.target) || event.target.closest(interactiveSelector)) return;
    const hit = hitAnnotation(point(event));
    if (hit?.tool !== 'arrow') return;
    event.preventDefault();
    event.stopImmediatePropagation();
    cancelGesture();
    finishCaption();
    state.selectedID = hit.id;
    const element = document.createElement('textarea');
    element.className = 'point-annotation-caption point-annotation-caption-editor';
    element.setAttribute('aria-label', 'Arrow caption');
    element.setAttribute('placeholder', 'Caption');
    element.setAttribute('data-html2canvas-ignore', 'true');
    element.value = hit.caption;
    state.editor = { id: hit.id, element };
    const resize = () => position(element, captionFrame(hit, element.value));
    element.addEventListener('input', resize);
    element.addEventListener('blur', () => finishCaption());
    element.addEventListener('keydown', event => {
      if (event.key === 'Enter' && !event.altKey && !event.shiftKey) { event.preventDefault(); finishCaption(); }
    });
    overlay.append(element);
    resize();
    render();
    element.focus({ preventScroll: true });
    element.select();
  }, true);

  document.addEventListener('keydown', event => {
    if (state.phase === 'idle') return;
    if (event.key === 'Escape') {
      event.preventDefault();
      setActive(false);
      return;
    }
    if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')) return;
    if (state.phase === 'active' && (event.metaKey || event.ctrlKey) && !event.altKey) {
      const key = event.key.toLowerCase();
      if (key === 'z' || (key === 'y' && event.ctrlKey)) {
        event.preventDefault();
        travelHistory(event.shiftKey || key === 'y' ? 'redo' : 'undo');
      }
    } else if (state.phase === 'active' && !event.metaKey && !event.ctrlKey && !event.altKey) {
      if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); deleteSelection(); }
      else {
        const tool = tools.find(tool => tool.key.toLowerCase() === event.key.toLowerCase());
        if (tool) { event.preventDefault(); selectTool(tool.id); }
      }
    }
  });
  activate.addEventListener('click', () => setActive(true));
  window.addEventListener('resize', async () => {
    if (state.phase !== 'active') return;
    cancelGesture();
    finishCaption();
    const generation = ++state.generation;
    state.phase = 'loading';
    render();
    try {
      const source = await captureSource(generation);
      if (generation !== state.generation) return;
      state.source = source;
      fitAnnotations();
      mosaicCache.clear();
      arrows.setAttribute('width', source.width);
      arrows.setAttribute('height', source.height);
      state.phase = 'active';
      render();
      announce('');
    } catch (error) {
      if (generation !== state.generation) return;
      setActive(false);
      announce('The resized page could not be captured. Choose “Try annotating” to retry.');
      console.error('Point annotation refresh failed', error);
    }
  });
  selectTool(state.tool);
})();
