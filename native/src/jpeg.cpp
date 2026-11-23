#include "jpeg.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace tej {
namespace {

const int kZigzag[64] = {0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
                         41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
                         30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

struct Huff {
  bool set = false;
  uint8_t vals[256];
  int mincode[17], maxcode[17], valptr[17];
  void build(const uint8_t* counts) {
    int code = 0, k = 0;
    for (int l = 1; l <= 16; l++) {
      valptr[l] = k;
      mincode[l] = code;
      code += counts[l];
      k += counts[l];
      maxcode[l] = counts[l] ? code - 1 : -1;
      code <<= 1;
    }
    set = true;
  }
};

struct Component {
  int id = 0, h = 1, v = 1, tq = 0;
  int dcTable = 0, acTable = 0;
  int pred = 0;
  int blocksW = 0, blocksH = 0;   // allocated blocks (padded to whole MCUs)
  int width = 0, height = 0;      // real size in samples
  std::vector<uint8_t> plane;     // blocksW * 8 by blocksH * 8
  std::vector<int16_t> coef;      // progressive only: 64 coefficients per block (natural order), kept until the last scan
  int qt[64];                     // progressive only: quantization table taken at the first scan of this channel
  bool qtTaken = false;
  bool done = false;
};

struct Reader {
  const uint8_t* d;
  size_t n, pos;
  uint32_t buf = 0;
  int cnt = 0;
  bool marker = false;  // hit a marker inside the entropy coded data: feed zeros

  int byte() { return pos < n ? d[pos++] : -1; }

  void fill() {
    while (cnt <= 24) {
      int b = 0;
      if (!marker) {
        if (pos >= n) { marker = true; }
        else {
          b = d[pos];
          if (b == 0xFF) {
            int b2 = pos + 1 < n ? d[pos + 1] : 0xD9;
            if (b2 == 0) pos += 2;
            else { marker = true; b = 0; }
          } else pos++;
        }
      }
      buf |= (uint32_t)b << (24 - cnt);
      cnt += 8;
    }
  }
  int bits(int k) {
    if (k == 0) return 0;
    if (cnt < k) fill();
    int v = (int)(buf >> (32 - k));
    buf <<= k;
    cnt -= k;
    return v;
  }
  int bit() { return bits(1); }
  void reset() { buf = 0; cnt = 0; marker = false; }
};

inline int extend(int v, int t) { return v < (1 << (t - 1)) ? v - (1 << t) + 1 : v; }

int decodeHuff(Reader& r, const Huff& h) {
  int code = 0;
  for (int l = 1; l <= 16; l++) {
    code = (code << 1) | r.bit();
    if (h.maxcode[l] >= 0 && code <= h.maxcode[l] && code >= h.mincode[l]) return h.vals[h.valptr[l] + code - h.mincode[l]];
  }
  return -1;
}

struct IdctTable {
  float c[8][8];
  IdctTable() {
    for (int x = 0; x < 8; x++)
      for (int u = 0; u < 8; u++)
        c[x][u] = (u == 0 ? std::sqrt(0.125f) : 0.5f) * std::cos((2 * x + 1) * u * 3.14159265358979f / 16.0f);
  }
};

void idct(const int* in, uint8_t* out, int stride) {
  static const IdctTable T;
  float tmp[64];
  for (int y = 0; y < 8; y++)        // rows
    for (int x = 0; x < 8; x++) {
      float s = 0;
      for (int u = 0; u < 8; u++) s += T.c[x][u] * in[y * 8 + u];
      tmp[y * 8 + x] = s;
    }
  for (int x = 0; x < 8; x++)        // columns
    for (int y = 0; y < 8; y++) {
      float s = 0;
      for (int v = 0; v < 8; v++) s += T.c[y][v] * tmp[v * 8 + x];
      int p = (int)std::lround(s) + 128;
      out[y * stride + x] = (uint8_t)(p < 0 ? 0 : (p > 255 ? 255 : p));
    }
}

}  // namespace

bool decodeJpeg(const uint8_t* data, size_t size, int& W, int& H, std::vector<uint8_t>& rgba, std::string& err) {
  auto fail = [&](const char* m) { err = m; return false; };
  if (!data || size < 4 || data[0] != 0xFF || data[1] != 0xD8) return fail("not a JPEG (no FFD8 start)");
  size_t pos = 2;
  int qt[4][64];
  bool qtSet[4] = {false, false, false, false};
  Huff dc[4], ac[4];
  std::vector<Component> comps;
  int width = 0, height = 0, hmax = 1, vmax = 1, restart = 0, adobe = -1;
  bool gotSof = false, anyScan = false, progressive = false;
  int mcusX = 0, mcusY = 0;

  auto u16 = [&](size_t p) { return (int)(data[p] << 8 | data[p + 1]); };

  while (pos + 4 <= size) {
    if (data[pos] != 0xFF) { pos++; continue; }
    int m = data[pos + 1];
    if (m == 0xFF) { pos++; continue; }
    if (m == 0x00 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { pos += 2; continue; }
    if (m == 0xD8) { pos += 2; continue; }
    if (m == 0xD9) break;
    if (pos + 4 > size) break;
    int len = u16(pos + 2);
    if (len < 2 || pos + 2 + len > size) return fail("JPEG segment is cut off");
    const uint8_t* seg = data + pos + 4;
    int segLen = len - 2;
    switch (m) {
      case 0xDB: {  // quantization tables
        int p = 0;
        while (p < segLen) {
          int pq = seg[p] >> 4, tq = seg[p] & 15;
          p++;
          if (tq > 3 || pq > 1) return fail("bad quantization table");
          if (p + (pq ? 128 : 64) > segLen) return fail("quantization table is cut off");
          for (int i = 0; i < 64; i++) {
            int v = pq ? (seg[p + i * 2] << 8 | seg[p + i * 2 + 1]) : seg[p + i];
            qt[tq][kZigzag[i]] = v;
          }
          p += pq ? 128 : 64;
          qtSet[tq] = true;
        }
        break;
      }
      case 0xC4: {  // huffman tables
        int p = 0;
        while (p + 17 <= segLen) {
          int tc = seg[p] >> 4, th = seg[p] & 15;
          if (tc > 1 || th > 3) return fail("bad Huffman table");
          uint8_t counts[17];
          counts[0] = 0;
          int total = 0;
          for (int i = 1; i <= 16; i++) { counts[i] = seg[p + i]; total += counts[i]; }
          if (total > 256 || p + 17 + total > segLen) return fail("Huffman table is cut off");
          Huff& hf = tc ? ac[th] : dc[th];
          std::memset(hf.vals, 0, sizeof hf.vals);
          std::memcpy(hf.vals, seg + p + 17, total);
          hf.build(counts);
          p += 17 + total;
        }
        break;
      }
      case 0xDD: if (segLen >= 2) restart = u16(pos + 4); break;
      case 0xEE: if (segLen >= 12 && std::memcmp(seg, "Adobe", 5) == 0) adobe = seg[11]; break;
      case 0xC0: case 0xC1: case 0xC2: {
        if (gotSof) return fail("two frame headers");
        if (segLen < 6) return fail("frame header is cut off");
        if (seg[0] != 8) return fail("only 8 bit JPEG is supported");
        height = u16(pos + 5);
        width = u16(pos + 7);
        int nc = seg[5];
        if (width <= 0 || height <= 0) return fail("JPEG has no size");
        if (width > 16384 || height > 16384 || (long long)width * height > 64000000LL) return fail("JPEG is too big");
        if (nc != 1 && nc != 3) return fail("only gray and 3 channel JPEG is supported (no CMYK)");
        if (segLen < 6 + nc * 3) return fail("frame header is cut off");
        comps.assign(nc, Component());
        for (int i = 0; i < nc; i++) {
          Component& c = comps[i];
          c.id = seg[6 + i * 3];
          c.h = seg[7 + i * 3] >> 4;
          c.v = seg[7 + i * 3] & 15;
          c.tq = seg[8 + i * 3];
          if (c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 || c.tq > 3) return fail("bad component in frame header");
          hmax = std::max(hmax, c.h);
          vmax = std::max(vmax, c.v);
        }
        if (nc == 1) { comps[0].h = comps[0].v = 1; hmax = vmax = 1; }
        mcusX = (width + 8 * hmax - 1) / (8 * hmax);
        mcusY = (height + 8 * vmax - 1) / (8 * vmax);
        for (auto& c : comps) {
          c.width = (width * c.h + hmax - 1) / hmax;
          c.height = (height * c.v + vmax - 1) / vmax;
          c.blocksW = mcusX * c.h;
          c.blocksH = mcusY * c.v;
          c.plane.assign((size_t)c.blocksW * 8 * c.blocksH * 8, 128);
        }
        progressive = (m == 0xC2);
        if (progressive) for (auto& c : comps) c.coef.assign((size_t)c.blocksW * c.blocksH * 64, 0);
        gotSof = true;
        break;
      }
      case 0xC3: case 0xC5: case 0xC6: case 0xC7: case 0xC9: case 0xCA: case 0xCB: case 0xCD: case 0xCE: case 0xCF:
        return fail("this kind of JPEG (lossless, hierarchical or arithmetic coded) is not supported");
      case 0xDA: {  // start of scan, then entropy coded data
        if (!gotSof) return fail("scan before frame header");
        if (segLen < 1) return fail("scan header is cut off");
        int ns = seg[0];
        if (ns < 1 || ns > (int)comps.size() || segLen < 1 + ns * 2 + 3) return fail("bad scan header");
        std::vector<int> idx;
        for (int i = 0; i < ns; i++) {
          int cid = seg[1 + i * 2];
          int ci = -1;
          for (size_t k = 0; k < comps.size(); k++) if (comps[k].id == cid) ci = (int)k;
          if (ci < 0) return fail("scan uses an unknown component");
          comps[ci].dcTable = seg[2 + i * 2] >> 4;
          comps[ci].acTable = seg[2 + i * 2] & 15;
          if (comps[ci].dcTable > 3 || comps[ci].acTable > 3) return fail("bad Huffman table number");
          idx.push_back(ci);
        }
        const int ss = seg[1 + ns * 2], se = seg[2 + ns * 2], ah = seg[3 + ns * 2] >> 4, al = seg[3 + ns * 2] & 15;
        if (progressive) {
          if (al > 13 || ah > 13) return fail("bad progressive scan (bit position)");
          if (ss == 0) { if (se != 0) return fail("bad progressive scan (DC scan with AC range)"); }
          else if (ns != 1 || se > 63 || ss > se) return fail("bad progressive scan (AC range)");
          if (ss == 0 && ah > 0 && al + 1 != ah) return fail("bad progressive scan (DC refinement step)");
          if (ss > 0 && ah > 0 && al + 1 != ah) return fail("bad progressive scan (AC refinement step)");
          for (int ci : idx) {
            if (ss == 0 && ah == 0 && !dc[comps[ci].dcTable].set) return fail("scan uses a Huffman table that was not defined");
            if (ss > 0 && !ac[comps[ci].acTable].set) return fail("scan uses a Huffman table that was not defined");
            if (!comps[ci].qtTaken) {
              if (!qtSet[comps[ci].tq]) return fail("scan uses a quantization table that was not defined");
              std::memcpy(comps[ci].qt, qt[comps[ci].tq], sizeof comps[ci].qt);
              comps[ci].qtTaken = true;
            }
          }
        } else {
          for (int ci : idx) {
            if (!dc[comps[ci].dcTable].set || !ac[comps[ci].acTable].set) return fail("scan uses a Huffman table that was not defined");
            if (!qtSet[comps[ci].tq]) return fail("scan uses a quantization table that was not defined");
          }
        }
        pos += 2 + len;
        Reader r{data, size, pos};
        for (int ci : idx) comps[ci].pred = 0;
        int total, perRow;
        bool interleaved = ns > 1;
        if (interleaved) { total = mcusX * mcusY; perRow = mcusX; }
        else {
          Component& c = comps[idx[0]];
          perRow = (c.width + 7) / 8;
          total = perRow * ((c.height + 7) / 8);
        }
        int block[64];
        int sinceRestart = 0;
        auto decodeBlock = [&](Component& c, int bx, int by) -> bool {
          std::memset(block, 0, sizeof block);
          int t = decodeHuff(r, dc[c.dcTable]);
          if (t < 0 || t > 11) return false;
          int diff = t ? extend(r.bits(t), t) : 0;
          c.pred += diff;
          block[0] = c.pred * qt[c.tq][0];
          for (int k = 1; k < 64;) {
            int rs = decodeHuff(r, ac[c.acTable]);
            if (rs < 0) return false;
            int run = rs >> 4, s = rs & 15;
            if (s == 0) { if (run == 15) { k += 16; continue; } break; }
            k += run;
            if (k > 63) return false;
            block[kZigzag[k]] = extend(r.bits(s), s) * qt[c.tq][kZigzag[k]];
            k++;
          }
          if (bx >= c.blocksW || by >= c.blocksH) return true;   // outside the padded plane: decoded, not stored
          idct(block, &c.plane[(size_t)by * 8 * c.blocksW * 8 + (size_t)bx * 8], c.blocksW * 8);
          return true;
        };
        int eobrun = 0;   // progressive: how many more blocks of this scan have no more coefficients
        auto decodeBlockProg = [&](Component& c, int bx, int by) -> bool {
          if (bx >= c.blocksW || by >= c.blocksH) {
            // outside the stored blocks (only happens with damaged sizes): read the bits, store nothing
            return false;
          }
          int16_t* blk = &c.coef[((size_t)by * c.blocksW + bx) * 64];
          if (ss == 0) {
            if (ah == 0) {   // DC, first pass
              int t = decodeHuff(r, dc[c.dcTable]);
              if (t < 0 || t > 11) return false;
              int diff = t ? extend(r.bits(t), t) : 0;
              c.pred += diff;
              blk[0] = (int16_t)(c.pred * (1 << al));
            } else {         // DC, refinement: one bit
              if (r.bit()) blk[0] = (int16_t)(blk[0] | (1 << al));
            }
            return true;
          }
          const Huff& ach = ac[c.acTable];
          if (ah == 0) {     // AC, first pass
            if (eobrun > 0) { eobrun--; return true; }
            for (int k = ss; k <= se; k++) {
              int rs = decodeHuff(r, ach);
              if (rs < 0) return false;
              int run = rs >> 4, s = rs & 15;
              if (s == 0) {
                if (run < 15) {
                  eobrun = (1 << run) - 1;
                  if (run) eobrun += r.bits(run);
                  break;
                }
                k += 15;     // 16 zeros (the loop adds the last one)
              } else {
                k += run;
                if (k > se) return false;
                blk[kZigzag[k]] = (int16_t)(extend(r.bits(s), s) * (1 << al));
              }
            }
            return true;
          }
          // AC, refinement pass (the tricky one: fixes known coefficients and finds new +1 / -1 ones)
          const int p1 = 1 << al, m1 = -(1 << al);
          int k = ss;
          auto fixOld = [&](int16_t& cf) {
            if (r.bit()) {
              if ((cf & p1) == 0) cf = (int16_t)(cf + (cf >= 0 ? p1 : m1));
            }
          };
          if (eobrun == 0) {
            for (; k <= se; k++) {
              int rs = decodeHuff(r, ach);
              if (rs < 0) return false;
              int run = rs >> 4, s = rs & 15, val = 0;
              if (s) {
                if (s != 1) return false;
                val = r.bit() ? p1 : m1;
              } else if (run != 15) {
                eobrun = 1 << run;
                if (run) eobrun += r.bits(run);
                break;
              }
              do {
                int16_t& cf = blk[kZigzag[k]];
                if (cf != 0) fixOld(cf);
                else if (--run < 0) break;
                k++;
              } while (k <= se);
              if (val) {
                if (k > se) return false;
                blk[kZigzag[k]] = (int16_t)val;
              }
            }
          }
          if (eobrun > 0) {
            for (; k <= se; k++) {
              int16_t& cf = blk[kZigzag[k]];
              if (cf != 0) fixOld(cf);
            }
            eobrun--;
          }
          return true;
        };
        bool ok = true;
        for (int mcu = 0; mcu < total && ok; mcu++) {
          if (restart > 0 && sinceRestart == restart) {
            // find the RSTn marker, byte aligned
            r.cnt = 0; r.buf = 0;
            size_t p = r.pos;
            while (p + 1 < size && !(data[p] == 0xFF && data[p + 1] >= 0xD0 && data[p + 1] <= 0xD7)) {
              if (data[p] == 0xFF && data[p + 1] != 0 && data[p + 1] != 0xFF && !(data[p + 1] >= 0xD0 && data[p + 1] <= 0xD7)) break;
              p++;
            }
            if (p + 1 < size && data[p] == 0xFF && data[p + 1] >= 0xD0 && data[p + 1] <= 0xD7) r.pos = p + 2;
            else { ok = false; break; }
            r.marker = false;
            for (int ci : idx) comps[ci].pred = 0;
            eobrun = 0;
            sinceRestart = 0;
          }
          if (interleaved) {
            int mx = mcu % perRow, my = mcu / perRow;
            for (int ci : idx) {
              Component& c = comps[ci];
              for (int v = 0; v < c.v && ok; v++)
                for (int h = 0; h < c.h && ok; h++) ok = progressive ? decodeBlockProg(c, mx * c.h + h, my * c.v + v) : decodeBlock(c, mx * c.h + h, my * c.v + v);
            }
          } else {
            ok = progressive ? decodeBlockProg(comps[idx[0]], mcu % perRow, mcu / perRow) : decodeBlock(comps[idx[0]], mcu % perRow, mcu / perRow);
          }
          sinceRestart++;
        }
        if (!ok && !anyScan) return fail("JPEG data is damaged (bad Huffman code)");
        if (!progressive || (ss == 0 && ah == 0)) for (int ci : idx) comps[ci].done = true;
        anyScan = true;
        // continue after the entropy data: find the next marker
        pos = r.pos;
        while (pos + 1 < size && !(data[pos] == 0xFF && data[pos + 1] != 0 && data[pos + 1] != 0xFF && !(data[pos + 1] >= 0xD0 && data[pos + 1] <= 0xD7))) pos++;
        continue;
      }
      default: break;   // APPn, COM, ...
    }
    pos += 2 + len;
  }
  if (!gotSof) return fail("JPEG has no frame header");
  if (!anyScan) return fail("JPEG has no image data");
  for (auto& c : comps) if (!c.done) return fail("JPEG is missing the data of a channel");
  if (progressive) {
    for (auto& c : comps) {
      const size_t stride = (size_t)c.blocksW * 8;
      int tmp[64];
      for (int by = 0; by < c.blocksH; by++)
        for (int bx = 0; bx < c.blocksW; bx++) {
          const int16_t* blk = &c.coef[((size_t)by * c.blocksW + bx) * 64];
          for (int i = 0; i < 64; i++) tmp[i] = blk[i] * c.qt[i];
          idct(tmp, &c.plane[(size_t)by * 8 * stride + (size_t)bx * 8], (int)stride);
        }
      std::vector<int16_t>().swap(c.coef);
    }
  }

  // Upsample every channel to the full size (centered, linear: like libjpeg "fancy" upsampling) and convert.
  W = width; H = height;
  rgba.assign((size_t)W * H * 4, 255);
  auto sample = [&](const Component& c, int x, int y) -> float {
    float fx, fy;
    if (c.h == hmax && c.v == vmax) return c.plane[(size_t)y * c.blocksW * 8 + x];
    fx = (x + 0.5f) * c.h / hmax - 0.5f;
    fy = (y + 0.5f) * c.v / vmax - 0.5f;
    fx = std::max(0.0f, std::min((float)(c.width - 1), fx));
    fy = std::max(0.0f, std::min((float)(c.height - 1), fy));
    int x0 = (int)fx, y0 = (int)fy;
    int x1 = std::min(c.width - 1, x0 + 1), y1 = std::min(c.height - 1, y0 + 1);
    float ax = fx - x0, ay = fy - y0;
    size_t st = (size_t)c.blocksW * 8;
    float a = c.plane[y0 * st + x0] * (1 - ax) + c.plane[y0 * st + x1] * ax;
    float b = c.plane[y1 * st + x0] * (1 - ax) + c.plane[y1 * st + x1] * ax;
    return a * (1 - ay) + b * ay;
  };
  bool rgbSource = comps.size() == 3 && adobe == 0;
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      uint8_t* o = &rgba[((size_t)y * W + x) * 4];
      if (comps.size() == 1) { uint8_t g = comps[0].plane[(size_t)y * comps[0].blocksW * 8 + x]; o[0] = o[1] = o[2] = g; continue; }
      float Y = sample(comps[0], x, y), Cb = sample(comps[1], x, y), Cr = sample(comps[2], x, y);
      float r, g, b;
      if (rgbSource) { r = Y; g = Cb; b = Cr; }
      else {
        r = Y + 1.402f * (Cr - 128.0f);
        g = Y - 0.344136f * (Cb - 128.0f) - 0.714136f * (Cr - 128.0f);
        b = Y + 1.772f * (Cb - 128.0f);
      }
      o[0] = (uint8_t)std::max(0, std::min(255, (int)std::lround(r)));
      o[1] = (uint8_t)std::max(0, std::min(255, (int)std::lround(g)));
      o[2] = (uint8_t)std::max(0, std::min(255, (int)std::lround(b)));
    }
  }
  return true;
}

}  // namespace tej
