/**
 * Minimal PNG decode/encode, enough to guarantee a true 32-bit RGBA file.
 *
 * This exists for one reason: Google Play's icon uploader requires a 32-bit
 * PNG, and every PNG encoder worth using drops the alpha channel when an
 * image turns out to be fully opaque. Rather than tricking an encoder into
 * keeping a channel it thinks is redundant, the pixels are decoded here and
 * written back out as RGBA.
 *
 * Supports 8-bit non-interlaced greyscale, RGB, and their alpha variants —
 * which covers everything this project generates. Anything else throws
 * rather than silently producing a wrong image.
 */

import { inflateSync, deflateSync } from 'node:zlib';

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = -1;
  for (let i = 0; i < buffer.length; i++) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

const paeth = (a, b, c) => {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
};

/** Decodes a PNG to `{ width, height, pixels }` with pixels as RGBA bytes. */
export function decode(buffer) {
  if (!buffer.subarray(0, 8).equals(SIGNATURE)) throw new Error('not a PNG');

  let width = 0;
  let height = 0;
  let colorType = 0;
  const idat = [];

  for (let offset = 8; offset < buffer.length;) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      const bitDepth = data[8];
      colorType = data[9];
      if (bitDepth !== 8) throw new Error(`unsupported bit depth ${bitDepth}`);
      if (data[12] !== 0) throw new Error('interlaced PNGs are not supported');
      if (![0, 2, 4, 6].includes(colorType)) {
        throw new Error(`unsupported colour type ${colorType} (palette?)`);
      }
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
    offset += 12 + length;
  }

  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(stride * height);

  // Undo the per-scanline filters, in place, one row at a time.
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const row = out.subarray(y * stride, (y + 1) * stride);
    const prior = y > 0 ? out.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? row[x - channels] : 0;
      const b = prior ? prior[x] : 0;
      const c = prior && x >= channels ? prior[x - channels] : 0;
      let value = line[x];
      if (filter === 1) value += a;
      else if (filter === 2) value += b;
      else if (filter === 3) value += (a + b) >> 1;
      else if (filter === 4) value += paeth(a, b, c);
      else if (filter !== 0) throw new Error(`unknown filter ${filter} on row ${y}`);
      row[x] = value & 0xff;
    }
  }

  // Normalise every input to RGBA so callers never branch on colour type.
  const pixels = Buffer.alloc(width * height * 4);
  for (let i = 0, p = 0; i < width * height; i++, p += 4) {
    const s = i * channels;
    if (channels === 1) {
      pixels[p] = pixels[p + 1] = pixels[p + 2] = out[s];
      pixels[p + 3] = 255;
    } else if (channels === 2) {
      pixels[p] = pixels[p + 1] = pixels[p + 2] = out[s];
      pixels[p + 3] = out[s + 1];
    } else if (channels === 3) {
      pixels[p] = out[s]; pixels[p + 1] = out[s + 1]; pixels[p + 2] = out[s + 2];
      pixels[p + 3] = 255;
    } else {
      out.copy(pixels, p, s, s + 4);
    }
  }
  return { width, height, pixels };
}

/** Encodes RGBA bytes as a 32-bit PNG (colour type 6), always keeping alpha. */
export function encodeRgba({ width, height, pixels }) {
  if (pixels.length !== width * height * 4) throw new Error('pixel buffer size mismatch');

  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;   // filter: none — the deflate pass does the work
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0);
    out.write(type, 4, 'ascii');
    data.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
    return out;
  };

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;    // bit depth
  ihdr[9] = 6;    // colour type: RGBA
  ihdr[10] = 0;   // deflate
  ihdr[11] = 0;   // adaptive filtering
  ihdr[12] = 0;   // non-interlaced

  return Buffer.concat([
    SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/** Reads a PNG's header without decoding the image data. */
export function inspect(buffer) {
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20),
    bitDepth: buffer[24],
    colorType: buffer[25],
    hasAlpha: buffer[25] === 4 || buffer[25] === 6,
    bytes: buffer.length,
  };
}
