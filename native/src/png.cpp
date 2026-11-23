#include "png.h"

#include <cstdlib>
#include <cstring>

namespace tej {
namespace {

// ------------------------------------------------------------ inflate

struct Bits {
  const uint8_t* p;
  size_t n;
  size_t pos = 0;
  uint32_t buf = 0;
  int cnt = 0;
  bool err = false;
  uint32_t get(int k) {
    while (cnt < k) {
      if (pos >= n) { err = true; return 0; }
      buf |= (uint32_t)p[pos++] << cnt;
      cnt += 8;
    }
    uint32_t v = buf & ((1u << k) - 1);
    buf >>= k;
    cnt -= k;
    return v;
  }
};

struct Huff {
  uint16_t count[16];
  uint16_t symbol[320];
};

void buildHuff(Huff& h, const uint8_t* lengths, int n) {
  for (int i = 0; i < 16; i++) h.count[i] = 0;
  for (int s = 0; s < n; s++) h.count[lengths[s]]++;
  uint16_t offs[16];
  offs[1] = 0;
  for (int len = 1; len < 15; len++) offs[len + 1] = offs[len] + h.count[len];
  for (int s = 0; s < n; s++) if (lengths[s]) h.symbol[offs[lengths[s]]++] = (uint16_t)s;
}

int decodeSym(Bits& b, const Huff& h) {
  int code = 0, first = 0, index = 0;
  for (int len = 1; len <= 15; len++) {
    code |= (int)b.get(1);
    if (b.err) return -1;
    int count = h.count[len];
    if (code - count < first) return h.symbol[index + (code - first)];
    index += count;
    first += count;
    first <<= 1;
    code <<= 1;
  }
  return -1;
}

const uint16_t kLenBase[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const uint8_t kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const uint16_t kDistBase[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
const uint8_t kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

bool inflateCodes(Bits& b, const Huff& lit, const Huff& dist, std::vector<uint8_t>& out, size_t limit) {
  for (;;) {
    int sym = decodeSym(b, lit);
    if (sym < 0) return false;
    if (sym < 256) {
      if (out.size() >= limit) return false;
      out.push_back((uint8_t)sym);
    } else if (sym == 256) {
      return true;
    } else {
      sym -= 257;
      if (sym >= 29) return false;
      int len = kLenBase[sym] + (int)b.get(kLenExtra[sym]);
      int ds = decodeSym(b, dist);
      if (ds < 0 || ds >= 30) return false;
      size_t d = kDistBase[ds] + b.get(kDistExtra[ds]);
      if (b.err || d > out.size() || out.size() + len > limit) return false;
      size_t from = out.size() - d;
      for (int i = 0; i < len; i++) out.push_back(out[from + i]);
    }
  }
}

bool inflateData(const uint8_t* data, size_t size, std::vector<uint8_t>& out, size_t limit) {
  if (size < 2) return false;
  Bits b{data + 2, size - 2};  // skip the zlib header
  for (;;) {
    uint32_t last = b.get(1), type = b.get(2);
    if (b.err) return false;
    if (type == 0) {
      b.buf = 0; b.cnt = 0;  // go to the byte border
      if (b.pos + 4 > b.n) return false;
      uint32_t len = b.p[b.pos] | (b.p[b.pos + 1] << 8);
      b.pos += 4;
      if (b.pos + len > b.n || out.size() + len > limit) return false;
      out.insert(out.end(), b.p + b.pos, b.p + b.pos + len);
      b.pos += len;
    } else if (type == 1) {
      uint8_t l[320];
      int i = 0;
      for (; i < 144; i++) l[i] = 8;
      for (; i < 256; i++) l[i] = 9;
      for (; i < 280; i++) l[i] = 7;
      for (; i < 288; i++) l[i] = 8;
      Huff lit, dist;
      buildHuff(lit, l, 288);
      uint8_t dl[30];
      for (int k = 0; k < 30; k++) dl[k] = 5;
      buildHuff(dist, dl, 30);
      if (!inflateCodes(b, lit, dist, out, limit)) return false;
    } else if (type == 2) {
      int nlen = (int)b.get(5) + 257, ndist = (int)b.get(5) + 1, ncode = (int)b.get(4) + 4;
      if (b.err || nlen > 286 || ndist > 30) return false;
      static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
      uint8_t lengths[320];
      std::memset(lengths, 0, sizeof lengths);
      for (int k = 0; k < ncode; k++) lengths[order[k]] = (uint8_t)b.get(3);
      Huff lencode;
      buildHuff(lencode, lengths, 19);
      uint8_t all[320];
      std::memset(all, 0, sizeof all);
      int idx = 0;
      while (idx < nlen + ndist) {
        int sym = decodeSym(b, lencode);
        if (sym < 0) return false;
        if (sym < 16) all[idx++] = (uint8_t)sym;
        else {
          int rep, val = 0;
          if (sym == 16) { if (idx == 0) return false; val = all[idx - 1]; rep = 3 + (int)b.get(2); }
          else if (sym == 17) rep = 3 + (int)b.get(3);
          else rep = 11 + (int)b.get(7);
          if (idx + rep > nlen + ndist) return false;
          while (rep--) all[idx++] = (uint8_t)val;
        }
      }
      Huff lit, dist;
      buildHuff(lit, all, nlen);
      buildHuff(dist, all + nlen, ndist);
      if (!inflateCodes(b, lit, dist, out, limit)) return false;
    } else return false;
    if (b.err) return false;
    if (last) return true;
  }
}

uint32_t be32(const uint8_t* p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

}  // namespace

bool decodePng(const uint8_t* d, size_t size, int& w, int& h, std::vector<uint8_t>& rgba, std::string& err) {
  static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
  if (size < 33 || std::memcmp(d, sig, 8) != 0) { err = "not a PNG"; return false; }
  size_t pos = 8;
  uint32_t width = 0, height = 0;
  int depth = 0, ctype = -1, interlace = 0;
  std::vector<uint8_t> idat, palette, trns;
  while (pos + 8 <= size) {
    uint32_t len = be32(d + pos);
    const uint8_t* type = d + pos + 4;
    pos += 8;
    if (pos + len + 4 > size) { err = "PNG chunk is cut short"; return false; }
    if (!std::memcmp(type, "IHDR", 4) && len >= 13) {
      width = be32(d + pos); height = be32(d + pos + 4);
      depth = d[pos + 8]; ctype = d[pos + 9]; interlace = d[pos + 12];
    } else if (!std::memcmp(type, "PLTE", 4)) palette.assign(d + pos, d + pos + len);
    else if (!std::memcmp(type, "tRNS", 4)) trns.assign(d + pos, d + pos + len);
    else if (!std::memcmp(type, "IDAT", 4)) idat.insert(idat.end(), d + pos, d + pos + len);
    else if (!std::memcmp(type, "IEND", 4)) break;
    pos += len + 4;
  }
  if (width == 0 || height == 0 || width > 16384 || height > 16384) { err = "bad PNG size"; return false; }
  if (interlace != 0) { err = "interlaced PNG is not supported"; return false; }
  if (depth != 8 && depth != 16) { err = "only 8 and 16 bit PNG is supported"; return false; }
  int channels;
  switch (ctype) { case 0: channels = 1; break; case 2: channels = 3; break; case 3: channels = 1; break;
                   case 4: channels = 2; break; case 6: channels = 4; break; default: err = "bad PNG color type"; return false; }
  if (ctype == 3 && (depth != 8 || palette.empty())) { err = "bad palette PNG"; return false; }
  size_t bpp = (size_t)channels * (depth / 8);
  size_t stride = bpp * width;
  size_t expected = (stride + 1) * height;
  std::vector<uint8_t> raw;
  raw.reserve(expected);
  if (!inflateData(idat.data(), idat.size(), raw, expected) || raw.size() != expected) { err = "PNG data is broken"; return false; }

  std::vector<uint8_t> img(stride * height);
  for (uint32_t y = 0; y < height; y++) {
    int filter = raw[y * (stride + 1)];
    const uint8_t* src = &raw[y * (stride + 1) + 1];
    uint8_t* dst = &img[y * stride];
    const uint8_t* up = y ? &img[(y - 1) * stride] : nullptr;
    for (size_t x = 0; x < stride; x++) {
      int a = x >= bpp ? dst[x - bpp] : 0;
      int b = up ? up[x] : 0;
      int c = (up && x >= bpp) ? up[x - bpp] : 0;
      int v = src[x];
      switch (filter) {
        case 0: break;
        case 1: v += a; break;
        case 2: v += b; break;
        case 3: v += (a + b) / 2; break;
        case 4: {
          int p = a + b - c, pa = std::abs(p - a), pb = std::abs(p - b), pc = std::abs(p - c);
          v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          break;
        }
        default: err = "bad PNG filter"; return false;
      }
      dst[x] = (uint8_t)v;
    }
  }
  w = (int)width; h = (int)height;
  rgba.assign((size_t)w * h * 4, 255);
  int step = depth / 8;
  for (uint32_t y = 0; y < height; y++) {
    for (uint32_t x = 0; x < width; x++) {
      const uint8_t* p = &img[y * stride + x * bpp];
      uint8_t* o = &rgba[((size_t)y * width + x) * 4];
      auto ch = [&](int i) { return p[i * step]; };  // high byte for 16 bit
      switch (ctype) {
        case 0: o[0] = o[1] = o[2] = ch(0); break;
        case 2: o[0] = ch(0); o[1] = ch(1); o[2] = ch(2); break;
        case 3: {
          size_t i = p[0];
          if (i * 3 + 2 < palette.size()) { o[0] = palette[i * 3]; o[1] = palette[i * 3 + 1]; o[2] = palette[i * 3 + 2]; }
          if (i < trns.size()) o[3] = trns[i];
          break;
        }
        case 4: o[0] = o[1] = o[2] = ch(0); o[3] = ch(1); break;
        case 6: o[0] = ch(0); o[1] = ch(1); o[2] = ch(2); o[3] = ch(3); break;
      }
    }
  }
  return true;
}

}  // namespace tej
