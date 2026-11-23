// Pure C++17 zero-dependency media encoder for flutter_tej3d:
// - PNG (RGBA8 stored zlib/DEFLATE + CRC32 + Adler32)
// - Baseline JPEG (YCbCr 4:4:4, 8x8 separable DCT, standard Annex K tables)
// - MJPEG-in-AVI 1.0 container (RIFF AVI + hdrl + movi + idx1)
// Zero external libraries (no libpng, no libjpeg, no zlib, no ffmpeg).
#include "media_enc.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace tej {

namespace {

inline void putBe32(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back((uint8_t)((v >> 24) & 0xFF));
  out.push_back((uint8_t)((v >> 16) & 0xFF));
  out.push_back((uint8_t)((v >> 8) & 0xFF));
  out.push_back((uint8_t)(v & 0xFF));
}

inline void putLe16(std::vector<uint8_t>& out, uint16_t v) {
  out.push_back((uint8_t)(v & 0xFF));
  out.push_back((uint8_t)((v >> 8) & 0xFF));
}

inline void putLe32(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back((uint8_t)(v & 0xFF));
  out.push_back((uint8_t)((v >> 8) & 0xFF));
  out.push_back((uint8_t)((v >> 16) & 0xFF));
  out.push_back((uint8_t)((v >> 24) & 0xFF));
}

inline void putFourCC(std::vector<uint8_t>& out, const char cc[4]) {
  out.push_back((uint8_t)cc[0]);
  out.push_back((uint8_t)cc[1]);
  out.push_back((uint8_t)cc[2]);
  out.push_back((uint8_t)cc[3]);
}

uint32_t crc32Update(uint32_t crc, const uint8_t* data, size_t len) {
  static uint32_t table[256];
  static bool ready = false;
  if (!ready) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      table[i] = c;
    }
    ready = true;
  }
  crc = ~crc;
  for (size_t i = 0; i < len; i++) crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
  return ~crc;
}

void writePngChunk(std::vector<uint8_t>& out, const char type[4], const uint8_t* data, size_t len) {
  putBe32(out, (uint32_t)len);
  size_t start = out.size();
  putFourCC(out, type);
  if (len > 0) out.insert(out.end(), data, data + len);
  uint32_t crc = crc32Update(0, out.data() + start, 4 + len);
  putBe32(out, crc);
}

// ---------------------------------------------------------------- JPEG tables (ITU-T T.81 Annex K)

static const uint8_t kZigZag[64] = {
   0,  1,  8, 16,  9,  2,  3, 10,
  17, 24, 32, 25, 18, 11,  4,  5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13,  6,  7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63
};

static const uint8_t kQuantY[64] = {
  16, 11, 10, 16, 24, 40, 51, 61,
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68,109,103, 77,
  24, 35, 55, 64, 81,104,113, 92,
  49, 64, 78, 87,103,121,120,101,
  72, 92, 95, 98,112,100,103, 99
};

static const uint8_t kQuantC[64] = {
  17, 18, 24, 47, 99, 99, 99, 99,
  18, 21, 26, 66, 99, 99, 99, 99,
  24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99
};

static const uint8_t kDcLumBits[16] = {0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0};
static const uint8_t kDcLumVals[12] = {0,1,2,3,4,5,6,7,8,9,10,11};

static const uint8_t kDcChrBits[16] = {0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0};
static const uint8_t kDcChrVals[12] = {0,1,2,3,4,5,6,7,8,9,10,11};

static const uint8_t kAcLumBits[16] = {0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d};
static const uint8_t kAcLumVals[162] = {
  0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,
  0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,
  0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,
  0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,
  0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
  0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,
  0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,
  0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,
  0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,
  0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
  0xf9,0xfa
};

static const uint8_t kAcChrBits[16] = {0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77};
static const uint8_t kAcChrVals[162] = {
  0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,
  0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,
  0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,
  0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,
  0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,
  0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,
  0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,
  0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,
  0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,
  0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
  0xf9,0xfa
};

struct HuffTable {
  uint16_t code[256];
  uint8_t size[256];
};

void buildHuffTable(const uint8_t bits[16], const uint8_t* vals, HuffTable& ht) {
  std::memset(&ht, 0, sizeof(ht));
  uint16_t code = 0;
  int idx = 0;
  for (int len = 1; len <= 16; len++) {
    for (int i = 0; i < bits[len - 1]; i++) {
      uint8_t sym = vals[idx++];
      ht.code[sym] = code++;
      ht.size[sym] = (uint8_t)len;
    }
    code <<= 1;
  }
}

struct BitWriter {
  std::vector<uint8_t>& out;
  uint32_t buf = 0;
  int bits = 0;

  void put(uint16_t code, int nbits) {
    buf = (buf << nbits) | (code & ((1u << nbits) - 1u));
    bits += nbits;
    while (bits >= 8) {
      bits -= 8;
      uint8_t b = (uint8_t)((buf >> bits) & 0xFFu);
      out.push_back(b);
      if (b == 0xFF) out.push_back(0x00);
    }
  }

  void flush() {
    if (bits > 0) {
      uint8_t b = (uint8_t)(((buf << (8 - bits)) | ((1u << (8 - bits)) - 1u)) & 0xFFu);
      out.push_back(b);
      if (b == 0xFF) out.push_back(0x00);
      buf = 0;
      bits = 0;
    }
  }
};

inline int bitCategory(int v) {
  int a = v < 0 ? -v : v;
  int c = 0;
  while (a > 0) { a >>= 1; c++; }
  return c;
}

void fdct8x8(const float in[64], float out[64]) {
  static float cosT[8][8];
  static bool ready = false;
  if (!ready) {
    const float kPi = 3.14159265358979323846f;
    for (int u = 0; u < 8; u++) {
      float alpha = (u == 0) ? 0.35355339f : 0.5f;  // 1/sqrt(8) or 1/2
      for (int x = 0; x < 8; x++) {
        cosT[u][x] = alpha * std::cos((2.0f * x + 1.0f) * u * kPi / 16.0f);
      }
    }
    ready = true;
  }
  float tmp[64];
  // 1D DCT on rows
  for (int y = 0; y < 8; y++) {
    const float* row = in + y * 8;
    for (int u = 0; u < 8; u++) {
      float sum = 0.0f;
      for (int x = 0; x < 8; x++) sum += row[x] * cosT[u][x];
      tmp[y * 8 + u] = sum;
    }
  }
  // 1D DCT on columns
  for (int u = 0; u < 8; u++) {
    for (int v = 0; v < 8; v++) {
      float sum = 0.0f;
      for (int y = 0; y < 8; y++) sum += tmp[y * 8 + u] * cosT[v][y];
      out[v * 8 + u] = sum;
    }
  }
}

void encodeBlock(BitWriter& bw, const float block[64], const uint8_t qtable[64],
                 const HuffTable& dcHuff, const HuffTable& acHuff, int& prevDc) {
  float dct[64];
  fdct8x8(block, dct);
  int zz[64];
  for (int i = 0; i < 64; i++) {
    float q = dct[kZigZag[i]] / (float)qtable[kZigZag[i]];
    zz[i] = (int)(q >= 0.0f ? (q + 0.5f) : (q - 0.5f));
  }
  // DC coefficient
  int diff = zz[0] - prevDc;
  prevDc = zz[0];
  int cat = bitCategory(diff);
  bw.put(dcHuff.code[cat], dcHuff.size[cat]);
  if (cat > 0) {
    int bits = diff < 0 ? (diff + (1 << cat) - 1) : diff;
    bw.put((uint16_t)bits, cat);
  }
  // AC coefficients
  int zeroRun = 0;
  for (int i = 1; i < 64; i++) {
    if (zz[i] == 0) {
      zeroRun++;
    } else {
      while (zeroRun >= 16) {
        bw.put(acHuff.code[0xF0], acHuff.size[0xF0]);
        zeroRun -= 16;
      }
      int acCat = bitCategory(zz[i]);
      uint8_t sym = (uint8_t)((zeroRun << 4) | acCat);
      bw.put(acHuff.code[sym], acHuff.size[sym]);
      int bits = zz[i] < 0 ? (zz[i] + (1 << acCat) - 1) : zz[i];
      bw.put((uint16_t)bits, acCat);
      zeroRun = 0;
    }
  }
  if (zeroRun > 0) {
    bw.put(acHuff.code[0x00], acHuff.size[0x00]);  // EOB
  }
}

void writeDht(std::vector<uint8_t>& out, uint8_t tcTh, const uint8_t bits[16], const uint8_t* vals, int nVals) {
  out.push_back(0xFF); out.push_back(0xC4);
  uint16_t len = (uint16_t)(2 + 1 + 16 + nVals);
  out.push_back((uint8_t)(len >> 8)); out.push_back((uint8_t)(len & 0xFF));
  out.push_back(tcTh);
  out.insert(out.end(), bits, bits + 16);
  out.insert(out.end(), vals, vals + nVals);
}

}  // namespace

// ---------------------------------------------------------------- Public PNG encoder

bool encodePng(int width, int height, const uint8_t* rgba, std::vector<uint8_t>& out) {
  out.clear();
  if (width <= 0 || height <= 0 || !rgba) return false;

  static const uint8_t kSig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
  out.insert(out.end(), kSig, kSig + 8);

  // IHDR
  std::vector<uint8_t> ihdr;
  putBe32(ihdr, (uint32_t)width);
  putBe32(ihdr, (uint32_t)height);
  ihdr.push_back(8);  // bit depth
  ihdr.push_back(6);  // RGBA
  ihdr.push_back(0);  // compression
  ihdr.push_back(0);  // filter
  ihdr.push_back(0);  // interlace
  writePngChunk(out, "IHDR", ihdr.data(), ihdr.size());

  // Raw filtered scanlines (filter byte 0 per row)
  const size_t rowBytes = (size_t)width * 4;
  const size_t rawSize = (size_t)height * (rowBytes + 1);
  std::vector<uint8_t> raw;
  raw.reserve(rawSize);
  uint32_t s1 = 1, s2 = 0;
  for (int y = 0; y < height; y++) {
    raw.push_back(0);
    s1 = (s1 + 0) % 65521u;
    s2 = (s2 + s1) % 65521u;
    const uint8_t* row = rgba + (size_t)y * rowBytes;
    raw.insert(raw.end(), row, row + rowBytes);
    for (size_t i = 0; i < rowBytes; i++) {
      s1 += row[i];
      if (s1 >= 65521u) s1 -= 65521u;
      s2 += s1;
      if (s2 >= 65521u) s2 -= 65521u;
    }
  }

  // Wrap in valid zlib stream with stored DEFLATE blocks (no external zlib)
  std::vector<uint8_t> zstream;
  zstream.reserve(rawSize + (rawSize / 65535 + 2) * 5 + 6);
  zstream.push_back(0x78);  // CMF: deflate, 32K window
  zstream.push_back(0x01);  // FLG: no dict, check bits valid (0x7801 % 31 == 0)
  size_t pos = 0;
  while (pos < raw.size()) {
    size_t chunk = std::min<size_t>(65535, raw.size() - pos);
    bool last = (pos + chunk == raw.size());
    zstream.push_back(last ? 0x01 : 0x00);
    uint16_t len16 = (uint16_t)chunk;
    uint16_t nlen16 = (uint16_t)(~len16);
    putLe16(zstream, len16);
    putLe16(zstream, nlen16);
    zstream.insert(zstream.end(), raw.data() + pos, raw.data() + pos + chunk);
    pos += chunk;
  }
  putBe32(zstream, (s2 << 16) | s1);

  writePngChunk(out, "IDAT", zstream.data(), zstream.size());
  writePngChunk(out, "IEND", nullptr, 0);
  return true;
}

// ---------------------------------------------------------------- Public JPEG encoder

bool encodeJpeg(int width, int height, const uint8_t* rgba, int quality, std::vector<uint8_t>& out) {
  out.clear();
  if (width <= 0 || height <= 0 || !rgba) return false;

  quality = std::max(1, std::min(100, quality));
  int scale = (quality < 50) ? (5000 / quality) : (200 - quality * 2);

  uint8_t qY[64], qC[64];
  for (int i = 0; i < 64; i++) {
    int yv = (kQuantY[i] * scale + 50) / 100;
    int cv = (kQuantC[i] * scale + 50) / 100;
    qY[i] = (uint8_t)std::max(1, std::min(255, yv));
    qC[i] = (uint8_t)std::max(1, std::min(255, cv));
  }

  static HuffTable dcLum, dcChr, acLum, acChr;
  static bool huffReady = false;
  if (!huffReady) {
    buildHuffTable(kDcLumBits, kDcLumVals, dcLum);
    buildHuffTable(kDcChrBits, kDcChrVals, dcChr);
    buildHuffTable(kAcLumBits, kAcLumVals, acLum);
    buildHuffTable(kAcChrBits, kAcChrVals, acChr);
    huffReady = true;
  }

  out.reserve((size_t)width * height / 2 + 1024);

  // SOI
  out.push_back(0xFF); out.push_back(0xD8);

  // APP0 (JFIF 1.01)
  static const uint8_t kApp0[18] = {
    0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00,
    0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00
  };
  out.insert(out.end(), kApp0, kApp0 + sizeof(kApp0));

  // DQT (Luminance id=0, Chrominance id=1)
  auto writeDqt = [&](uint8_t id, const uint8_t q[64]) {
    out.push_back(0xFF); out.push_back(0xDB);
    out.push_back(0x00); out.push_back(67);
    out.push_back(id);
    for (int i = 0; i < 64; i++) out.push_back(q[kZigZag[i]]);
  };
  writeDqt(0, qY);
  writeDqt(1, qC);

  // SOF0 (Baseline DCT, 3 components, 4:4:4)
  out.push_back(0xFF); out.push_back(0xC0);
  out.push_back(0x00); out.push_back(17);
  out.push_back(8);  // precision
  out.push_back((uint8_t)((height >> 8) & 0xFF));
  out.push_back((uint8_t)(height & 0xFF));
  out.push_back((uint8_t)((width >> 8) & 0xFF));
  out.push_back((uint8_t)(width & 0xFF));
  out.push_back(3);  // Y, Cb, Cr
  out.push_back(1); out.push_back(0x11); out.push_back(0);
  out.push_back(2); out.push_back(0x11); out.push_back(1);
  out.push_back(3); out.push_back(0x11); out.push_back(1);

  // DHT tables
  writeDht(out, 0x00, kDcLumBits, kDcLumVals, 12);
  writeDht(out, 0x10, kAcLumBits, kAcLumVals, 162);
  writeDht(out, 0x01, kDcChrBits, kDcChrVals, 12);
  writeDht(out, 0x11, kAcChrBits, kAcChrVals, 162);

  // SOS
  static const uint8_t kSos[14] = {
    0xFF, 0xDA, 0x00, 0x0C, 0x03,
    0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
    0x00, 0x3F, 0x00
  };
  out.insert(out.end(), kSos, kSos + sizeof(kSos));

  BitWriter bw{out};
  int prevDcY = 0, prevDcCb = 0, prevDcCr = 0;
  float blkY[64], blkCb[64], blkCr[64];

  for (int by = 0; by < height; by += 8) {
    for (int bx = 0; bx < width; bx += 8) {
      for (int dy = 0; dy < 8; dy++) {
        int py = std::min(height - 1, by + dy);
        for (int dx = 0; dx < 8; dx++) {
          int px = std::min(width - 1, bx + dx);
          const uint8_t* p = rgba + ((size_t)py * width + px) * 4;
          float r = p[0], g = p[1], b = p[2];
          int idx = dy * 8 + dx;
          blkY[idx]  =  0.299f * r + 0.587f * g + 0.114f * b - 128.0f;
          blkCb[idx] = -0.168736f * r - 0.331264f * g + 0.5f * b;
          blkCr[idx] =  0.5f * r - 0.418688f * g - 0.081312f * b;
        }
      }
      encodeBlock(bw, blkY,  qY, dcLum, acLum, prevDcY);
      encodeBlock(bw, blkCb, qC, dcChr, acChr, prevDcCb);
      encodeBlock(bw, blkCr, qC, dcChr, acChr, prevDcCr);
    }
  }
  bw.flush();

  // EOI
  out.push_back(0xFF); out.push_back(0xD9);
  return true;
}

// ---------------------------------------------------------------- MJPEG-AVI 1.0 Recorder

void VideoRecorder::begin(int w, int h, int targetFps, int jpegQuality) {
  width = w;
  height = h;
  fps = std::max(1, std::min(120, targetFps));
  quality = std::max(1, std::min(100, jpegQuality));
  frames.clear();
  active = (w > 0 && h > 0);
}

bool VideoRecorder::addFrame(const uint8_t* rgba) {
  if (!active || !rgba) return false;
  std::vector<uint8_t> jpg;
  if (!encodeJpeg(width, height, rgba, quality, jpg)) return false;
  frames.push_back(std::move(jpg));
  return true;
}

bool VideoRecorder::finish(std::vector<uint8_t>& out) {
  out.clear();
  if (!active || frames.empty()) {
    active = false;
    return false;
  }

  const uint32_t numFrames = (uint32_t)frames.size();
  const uint32_t usPerFrame = 1000000u / (uint32_t)fps;
  uint32_t maxFrameSize = 0;
  uint32_t moviPayload = 4;  // "movi"
  for (const auto& f : frames) {
    uint32_t sz = (uint32_t)f.size();
    if (sz > maxFrameSize) maxFrameSize = sz;
    moviPayload += 8 + sz + (sz & 1u);
  }

  // Build hdrl LIST content
  std::vector<uint8_t> hdrl;
  putFourCC(hdrl, "hdrl");

  // avih (56 bytes)
  putFourCC(hdrl, "avih");
  putLe32(hdrl, 56);
  putLe32(hdrl, usPerFrame);
  putLe32(hdrl, maxFrameSize * (uint32_t)fps);  // maxBytesPerSec
  putLe32(hdrl, 0);                             // paddingGranularity
  putLe32(hdrl, 0x10u);                         // AVIF_HASINDEX
  putLe32(hdrl, numFrames);
  putLe32(hdrl, 0);                             // initialFrames
  putLe32(hdrl, 1);                             // streams
  putLe32(hdrl, maxFrameSize);                  // suggestedBufferSize
  putLe32(hdrl, (uint32_t)width);
  putLe32(hdrl, (uint32_t)height);
  putLe32(hdrl, 0); putLe32(hdrl, 0); putLe32(hdrl, 0); putLe32(hdrl, 0);

  // strl LIST
  std::vector<uint8_t> strl;
  putFourCC(strl, "strl");

  // strh (56 bytes)
  putFourCC(strl, "strh");
  putLe32(strl, 56);
  putFourCC(strl, "vids");
  putFourCC(strl, "MJPG");
  putLe32(strl, 0);                 // flags
  putLe16(strl, 0); putLe16(strl, 0);  // priority, language
  putLe32(strl, 0);                 // initialFrames
  putLe32(strl, 1);                 // scale
  putLe32(strl, (uint32_t)fps);     // rate
  putLe32(strl, 0);                 // start
  putLe32(strl, numFrames);         // length
  putLe32(strl, maxFrameSize);      // suggestedBufferSize
  putLe32(strl, 0xFFFFFFFFu);       // quality (default)
  putLe32(strl, 0);                 // sampleSize
  putLe16(strl, 0); putLe16(strl, 0);
  putLe16(strl, (uint16_t)width);
  putLe16(strl, (uint16_t)height);

  // strf (BITMAPINFOHEADER, 40 bytes)
  putFourCC(strl, "strf");
  putLe32(strl, 40);
  putLe32(strl, 40);                // biSize
  putLe32(strl, (uint32_t)width);   // biWidth
  putLe32(strl, (uint32_t)height);  // biHeight
  putLe16(strl, 1);                 // biPlanes
  putLe16(strl, 24);                // biBitCount
  putFourCC(strl, "MJPG");          // biCompression
  putLe32(strl, (uint32_t)(width * height * 3));  // biSizeImage
  putLe32(strl, 0); putLe32(strl, 0); putLe32(strl, 0); putLe32(strl, 0);

  putFourCC(hdrl, "LIST");
  putLe32(hdrl, (uint32_t)strl.size());
  hdrl.insert(hdrl.end(), strl.begin(), strl.end());

  const uint32_t idxSize = numFrames * 16u;
  const uint32_t riffSize = 4 + (8 + (uint32_t)hdrl.size()) + (8 + moviPayload) + (8 + idxSize);

  out.reserve(8 + riffSize);
  putFourCC(out, "RIFF");
  putLe32(out, riffSize);
  putFourCC(out, "AVI ");

  // hdrl LIST
  putFourCC(out, "LIST");
  putLe32(out, (uint32_t)hdrl.size());
  out.insert(out.end(), hdrl.begin(), hdrl.end());

  // movi LIST
  putFourCC(out, "LIST");
  putLe32(out, moviPayload);
  putFourCC(out, "movi");

  std::vector<uint32_t> offsets;
  offsets.reserve(numFrames);
  uint32_t relOffset = 4;  // offset from start of "movi"
  for (const auto& f : frames) {
    offsets.push_back(relOffset);
    uint32_t sz = (uint32_t)f.size();
    putFourCC(out, "00dc");
    putLe32(out, sz);
    out.insert(out.end(), f.begin(), f.end());
    if (sz & 1u) out.push_back(0);
    relOffset += 8 + sz + (sz & 1u);
  }

  // idx1 chunk
  putFourCC(out, "idx1");
  putLe32(out, idxSize);
  for (uint32_t i = 0; i < numFrames; i++) {
    putFourCC(out, "00dc");
    putLe32(out, 0x10u);  // AVIIF_KEYFRAME
    putLe32(out, offsets[i]);
    putLe32(out, (uint32_t)frames[i].size());
  }

  frames.clear();
  active = false;
  return true;
}

}  // namespace tej
