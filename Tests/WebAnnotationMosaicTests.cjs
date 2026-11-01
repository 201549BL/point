const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class PixelCanvas {
  constructor(width = 0, height = 0, pixels) {
    this._width = width;
    this._height = height;
    this.pixels = pixels || new Uint8ClampedArray(width * height * 4);
    this.style = {};
  }
  get width() { return this._width; }
  set width(value) { this._width = value; this.pixels = new Uint8ClampedArray(value * this.height * 4); }
  get height() { return this._height; }
  set height(value) { this._height = value; this.pixels = new Uint8ClampedArray(this.width * value * 4); }
  getContext() {
    return {
      createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
      getImageData: (x, y, width, height) => {
        const data = new Uint8ClampedArray(width * height * 4);
        for (let row = 0; row < height; row++) {
          const start = ((y + row) * this.width + x) * 4;
          data.set(this.pixels.subarray(start, start + width * 4), row * width * 4);
        }
        return { width, height, data };
      },
      putImageData: (image, x, y) => {
        for (let row = 0; row < image.height; row++) {
          const start = row * image.width * 4;
          this.pixels.set(image.data.subarray(start, start + image.width * 4), ((y + row) * this.width + x) * 4);
        }
      },
    };
  }
}

const context = {
  window: {},
  document: { currentScript: { src: 'http://localhost/annotation-mosaic.js' } },
  TextEncoder, Uint8Array,
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../docs/annotation-mosaic.js'), 'utf8'), context);
const { render } = context.window.PointMosaic;
const id = '01234567-89ab-cdef-0123-456789abcdef';
const fixture = new PixelCanvas(96, 64);
for (let y = 0; y < fixture.height; y++) {
  for (let x = 0; x < fixture.width; x++) {
    fixture.pixels.set(y < 32 ? [255, x * 2, 0, 255] : [0, x * 2, 255, 255], (y * fixture.width + x) * 4);
  }
}
const source = { canvas: fixture, scale: 1, width: 96, height: 64 };
const rect = { x: 0, y: 0, width: 96, height: 64 };
const output = new PixelCanvas();
render(output, source, rect, id);
assert.equal(output.width, 96);
assert.equal(output.height, 64);
assert.ok(output.pixels.every((value, index) => index % 4 !== 3 || value === 255), 'mosaic must cover every source pixel without transparent seams');
assert.equal(output.pixels[0], 255, 'top source colors must remain at the top');
assert.equal(output.pixels[(63 * 96) * 4 + 2], 255, 'bottom source colors must remain at the bottom');
const repeated = new PixelCanvas();
render(repeated, source, rect, id);
assert.deepEqual(repeated.pixels, output.pixels, 'redraw must keep the same tile pattern');
render(repeated, source, rect, 'fedcba98-7654-3210-fedc-ba9876543210');
assert.notDeepEqual(repeated.pixels, output.pixels, 'separate annotations must have distinct tile patterns');
const colors = new Set();
for (let offset = 0; offset < output.pixels.length; offset += 4) colors.add(output.pixels.slice(offset, offset + 3).join(','));
assert.ok(colors.size > 2 && colors.size < 100, 'mosaic must average source colors into coarse cells');
render(repeated, source, { x: 0, y: 40, width: 40, height: 20 }, id);
assert.equal(repeated.pixels[0], 0, 'a moved mosaic must sample its new source region');
assert.equal(repeated.pixels[2], 255);
render(repeated, source, { x: -10, y: 0, width: 30, height: 20 }, id);
assert.equal(repeated.pixels[3], 0, 'out-of-source area must stay outside the captured image');
assert.equal(repeated.pixels[10 * 4 + 3], 255, 'in-source portion must still render');
render(repeated, { ...source, scale: 2 }, { x: 0, y: 0, width: 20, height: 10 }, id);
assert.equal(repeated.width, 40, 'tile sizing must follow physical capture pixels');
assert.equal(repeated.height, 20);
render(repeated, source, { x: 0, y: 0, width: 0, height: 20 }, id);
assert.equal(repeated.pixels.length, 0);
console.log('Mosaic tests passed: deterministic cells, source colors, orientation, coverage, movement, clipping, and capture scale.');
