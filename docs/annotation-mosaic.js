(() => {
  "use strict";

  const tileSize = 22;
  const scriptURL = document.currentScript?.src || document.baseURI;
  let rendererPromise;

  function pageRenderer() {
    if (typeof window.html2canvas === "function") return Promise.resolve(window.html2canvas);
    if (!rendererPromise) {
      rendererPromise = new Promise((resolve, reject) => {
        const url = new URL("vendor/html2canvas.min.js", scriptURL);
        if (url.origin !== window.location.origin) {
          reject(new Error("The page capture renderer must be served from this site."));
          return;
        }
        const script = document.createElement("script");
        script.src = url.href;
        script.onload = () => {
          if (typeof window.html2canvas === "function") resolve(window.html2canvas);
          else reject(new Error("The page capture renderer did not initialize."));
        };
        script.onerror = () => reject(new Error("The page capture renderer could not be loaded."));
        document.head.append(script);
      }).catch((error) => {
        rendererPromise = undefined;
        throw error;
      });
    }
    return rendererPromise;
  }

  async function capture() {
    const renderer = await pageRenderer();
    await document.fonts?.ready;
    const root = document.documentElement;
    const body = document.body;
    const width = Math.max(root.clientWidth, root.scrollWidth, body.scrollWidth);
    const height = Math.max(root.clientHeight, root.scrollHeight, body.scrollHeight);
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    const canvas = await renderer(root, {
      width,
      height,
      x: 0,
      y: 0,
      scale,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      windowWidth: window.innerWidth,
      windowHeight: window.innerHeight,
      logging: false,
      allowTaint: false,
      useCORS: false,
      ignoreElements: (element) => element.hasAttribute("data-html2canvas-ignore"),
    });
    canvas.getContext("2d").getImageData(0, 0, 1, 1);
    return { canvas, scale, width, height };
  }

  function randomFor(id) {
    const mask = (1n << 64n) - 1n;
    const uuid = String(id).replaceAll("-", "");
    const bytes = /^[0-9a-f]{32}$/i.test(uuid)
      ? Uint8Array.from(uuid.match(/../g), (byte) => parseInt(byte, 16))
      : new TextEncoder().encode(String(id));
    let state = 14695981039346656037n;
    for (const byte of bytes) state = ((state ^ BigInt(byte)) * 1099511628211n) & mask;
    return () => {
      state = (state + 0x9e3779b97f4a7c15n) & mask;
      let value = state;
      value = ((value ^ (value >> 30n)) * 0xbf58476d1ce4e5b9n) & mask;
      value = ((value ^ (value >> 27n)) * 0x94d049bb133111ebn) & mask;
      value ^= value >> 31n;
      return (Number(value >> 11n) / 9007199254740992) * 2 - 1;
    };
  }

  function clip(polygon, site, neighbor) {
    if (!polygon.length) return polygon;
    const normalX = neighbor.x - site.x;
    const normalY = neighbor.y - site.y;
    const boundary = (neighbor.x ** 2 + neighbor.y ** 2 - site.x ** 2 - site.y ** 2) / 2;
    const result = [];
    let previous = polygon[polygon.length - 1];
    let previousDistance = boundary - normalX * previous.x - normalY * previous.y;
    for (const current of polygon) {
      const currentDistance = boundary - normalX * current.x - normalY * current.y;
      if ((previousDistance >= 0) !== (currentDistance >= 0)) {
        const amount = previousDistance / (previousDistance - currentDistance);
        result.push({
          x: previous.x + (current.x - previous.x) * amount,
          y: previous.y + (current.y - previous.y) * amount,
        });
      }
      if (currentDistance >= 0) result.push(current);
      previous = current;
      previousDistance = currentDistance;
    }
    return result;
  }

  function averageColor(site, samples, width, height) {
    const centerX = Math.min(width - 1, Math.max(0, Math.round(site.x)));
    // The native sites use a bottom-left origin. ImageData rows start at the top.
    const centerY = height - 1 - Math.min(height - 1, Math.max(0, Math.round(site.y)));
    const color = [0, 0, 0, 0];
    let count = 0;
    for (let y = Math.max(0, centerY - 4); y <= Math.min(height - 1, centerY + 4); y++) {
      for (let x = Math.max(0, centerX - 4); x <= Math.min(width - 1, centerX + 4); x++) {
        const offset = (y * width + x) * 4;
        for (let channel = 0; channel < 4; channel++) color[channel] += samples[offset + channel];
        count++;
      }
    }
    return color.map((value) => Math.round(value / count));
  }

  function fillPolygon(polygon, color, output, width, height) {
    const points = polygon.map((point) => ({ x: point.x, y: height - point.y }));
    const firstRow = Math.max(0, Math.ceil(Math.min(...points.map((point) => point.y)) - 0.5));
    const lastRow = Math.min(height, Math.ceil(Math.max(...points.map((point) => point.y)) - 0.5));
    // Scan conversion writes whole pixels. Canvas path fills would antialias cell borders.
    for (let y = firstRow; y < lastRow; y++) {
      const scanY = y + 0.5;
      let left = Infinity;
      let right = -Infinity;
      let previous = points[points.length - 1];
      for (const current of points) {
        if ((previous.y <= scanY && current.y > scanY) || (current.y <= scanY && previous.y > scanY)) {
          const x = previous.x + ((scanY - previous.y) / (current.y - previous.y)) * (current.x - previous.x);
          left = Math.min(left, x);
          right = Math.max(right, x);
        }
        previous = current;
      }
      const start = Math.max(0, Math.ceil(left - 0.5));
      const end = Math.min(width, Math.ceil(right - 0.5));
      for (let x = start; x < end; x++) {
        const offset = (y * width + x) * 4;
        output[offset] = color[0];
        output[offset + 1] = color[1];
        output[offset + 2] = color[2];
        output[offset + 3] = color[3];
      }
    }
  }

  function render(targetCanvas, source, rect, id) {
    const values = [rect.x, rect.y, rect.width, rect.height, source.scale];
    if (!values.every(Number.isFinite) || source.scale <= 0) {
      throw new TypeError("A mosaic needs a finite rectangle and positive capture scale.");
    }
    const x = Math.min(rect.x, rect.x + rect.width);
    const y = Math.min(rect.y, rect.y + rect.height);
    const width = Math.abs(rect.width);
    const height = Math.abs(rect.height);
    targetCanvas.width = Math.ceil(width * source.scale);
    targetCanvas.height = Math.ceil(height * source.scale);
    targetCanvas.style.width = `${width}px`;
    targetCanvas.style.height = `${height}px`;
    if (!targetCanvas.width || !targetCanvas.height) return;

    const originX = Math.floor(x * source.scale);
    const originY = Math.floor(y * source.scale);
    const cropX = Math.max(0, originX);
    const cropY = Math.max(0, originY);
    const cropWidth = Math.min(source.canvas.width, originX + targetCanvas.width) - cropX;
    const cropHeight = Math.min(source.canvas.height, originY + targetCanvas.height) - cropY;
    if (cropWidth <= 0 || cropHeight <= 0) return;

    const samples = source.canvas.getContext("2d").getImageData(cropX, cropY, cropWidth, cropHeight).data;
    const context = targetCanvas.getContext("2d");
    const output = context.createImageData(cropWidth, cropHeight);
    const columns = Math.max(1, Math.ceil(cropWidth / tileSize));
    const rows = Math.max(1, Math.ceil(cropHeight / tileSize));
    const random = randomFor(id);
    const sites = [];
    for (let row = 0; row < rows; row++) {
      for (let column = 0; column < columns; column++) {
        sites.push({
          x: Math.min(cropWidth - 0.5, Math.max(0.5, (column + 0.5) * tileSize + random() * tileSize * 0.32)),
          y: Math.min(cropHeight - 0.5, Math.max(0.5, (row + 0.5) * tileSize + random() * tileSize * 0.32)),
        });
      }
    }
    for (let row = 0; row < rows; row++) {
      for (let column = 0; column < columns; column++) {
        const index = row * columns + column;
        const site = sites[index];
        let polygon = [{ x: 0, y: 0 }, { x: cropWidth, y: 0 }, { x: cropWidth, y: cropHeight }, { x: 0, y: cropHeight }];
        for (let neighborRow = Math.max(0, row - 2); neighborRow <= Math.min(rows - 1, row + 2) && polygon.length; neighborRow++) {
          for (let neighborColumn = Math.max(0, column - 2); neighborColumn <= Math.min(columns - 1, column + 2) && polygon.length; neighborColumn++) {
            const neighborIndex = neighborRow * columns + neighborColumn;
            if (neighborIndex !== index) polygon = clip(polygon, site, sites[neighborIndex]);
          }
        }
        if (polygon.length >= 3) fillPolygon(polygon, averageColor(site, samples, cropWidth, cropHeight), output.data, cropWidth, cropHeight);
      }
    }
    context.putImageData(output, cropX - originX, cropY - originY);
    return { x: cropX / source.scale, y: cropY / source.scale, width: cropWidth / source.scale, height: cropHeight / source.scale };
  }

  window.PointMosaic = Object.freeze({ capture, render });
})();
