// FingerprintIcons: Maps combined fingerprint string to Material Icon sequence
// Uses 260 Material Icons code points (matching LocalSend v1.18 icon alphabet)
// as the "alphabet" for converting a SHA-256 hash into a visual icon grid.
//
// Algorithm (matching LocalSend Dart reference fingerprint_alphabet.dart):
//   1. SHA-256(combined fingerprint string) → 64-char hex
//   2. Take first 16 bytes (32 hex chars) of the hash
//   3. Calculate result length: ceil(32 * 4 * ln(2) / ln(260))
//   4. BigInt-style base-260 conversion: repeatedly divide hex by 260,
//      collect remainders (LSB first), then reverse into final array
//   5. Result: ~15 icons for 4×4 grid display
//
// Note: BigInt is prohibited in ArkTS. We simulate BigInt division using
// hex long-division (divideHexByDecimal), which processes digit by digit.

import { nativeComputeFingerprintHash } from '../service/NativeBridge';

// Material Icons code points from Flutter's Icons class (LocalSend v1.18 fingerprint_alphabet.dart)
// These map to glyphs in MaterialIcons-Regular.otf (rawfile/materialicons-regular.otf)
const ICON_CODE_POINTS: number[] = [
  0xE037, 0xE03C, 0xE063, 0xE072, 0xE076, 0xE084, 0xE085, 0xE089, 0xF04BE, 0xE090,
  0xE0B1, 0xE0B2, 0xE0B6, 0xF04C5, 0xE0C4, 0xE0C8, 0xE0C9, 0xF04C6, 0xE0CF, 0xE0D2,
  0xE0DD, 0xE0DF, 0xE0E0, 0xE0E4, 0xE0EE, 0xE0F1, 0xE113, 0xE115, 0xE116, 0xE11E,
  0xE120, 0xE121, 0xE122, 0xE138, 0xE143, 0xE144, 0xF04CB, 0xE149, 0xF04CC, 0xE14D,
  0xE151, 0xE153, 0xE15D, 0xF04CD, 0xE163, 0xE16F, 0xE179, 0xE17D, 0xE185, 0xE186,
  0xE191, 0xF0858, 0xF04D9, 0xE199, 0xE19B, 0xE19F, 0xF04DA, 0xF0797, 0xE1B9, 0xF04ED,
  0xE1D2, 0xE1D3, 0xE1D5, 0xE1D7, 0xE1FC, 0xE214, 0xE217, 0xE21A, 0xF04F8, 0xE229,
  0xE22A, 0xE22C, 0xE22F, 0xE234, 0xE248, 0xE250, 0xE252, 0xF04FD, 0xE25A, 0xE25B,
  0xE262, 0xE263, 0xE287, 0xE288, 0xE28A, 0xE28D, 0xE28E, 0xE295, 0xE297, 0xE2A0,
  0xF0866, 0xE2BB, 0xE2D3, 0xE2E4, 0xE2EE, 0xF06BE, 0xE2F3, 0xE2FF, 0xE304, 0xE306,
  0xF0517, 0xE315, 0xF0518, 0xE318, 0xE325, 0xE32A, 0xF051D, 0xE330, 0xE331, 0xE34A,
  0xE34E, 0xF052A, 0xF052B, 0xE351, 0xE35D, 0xE35E, 0xE365, 0xE36D, 0xE379, 0xE37B,
  0xE380, 0xE383, 0xE38C, 0xE38D, 0xE391, 0xE393, 0xE394, 0xE398, 0xE39A, 0xE3A0,
  0xE3A6, 0xE3A7, 0xE3A8, 0xE3AE, 0xE3C1, 0xE3C8, 0xE3D2, 0xE3D3, 0xE3D9, 0xE3DB,
  0xE3DC, 0xE3DD, 0xE3E1, 0xE3E6, 0xE3E7, 0xF053D, 0xE3FE, 0xF053E, 0xE40A, 0xE40B,
  0xE40D, 0xE414, 0xF0541, 0xE42E, 0xE44F, 0xF07B7, 0xE463, 0xE465, 0xE46B, 0xE478,
  0xF0546, 0xE491, 0xE4A1, 0xF0548, 0xE4A2, 0xE4B6, 0xE4BE, 0xE4C3, 0xE4C9, 0xE4DC,
  0xE4E0, 0xE4E4, 0xE4EA, 0xF07BA, 0xE4EF, 0xE4F0, 0xE4F4, 0xE4F5, 0xE501, 0xE502,
  0xE506, 0xE50C, 0xF055A, 0xE511, 0xE514, 0xE532, 0xF055C, 0xE53D, 0xF0561, 0xE542,
  0xE54D, 0xF0562, 0xE553, 0xE559, 0xE55A, 0xE567, 0xE57F, 0xF0877, 0xE596, 0xE59B,
  0xE59C, 0xE5A0, 0xF0569, 0xE5B7, 0xE5C5, 0xE5C6, 0xE5C8, 0xE5D0, 0xF07C6, 0xE5DB,
  0xE5E8, 0xE5E9, 0xE5EA, 0xE5EC, 0xE5EF, 0xE5F2, 0xE5F3, 0xF0570, 0xF0572, 0xE5F8,
  0xE5F9, 0xE60A, 0xE60E, 0xE612, 0xF0585, 0xE640, 0xF0587, 0xE654, 0xE655, 0xE656,
  0xE65B, 0xE66C, 0xE66D, 0xF07CC, 0xE672, 0xE674, 0xE675, 0xE683, 0xE68A, 0xE697,
  0xF0597, 0xE6A8, 0xE6B4, 0xE6BD, 0xE6C1, 0xF07D3, 0xF07D4, 0xF05A0, 0xE6CB, 0xE6CE,
  0xF05A2, 0xE6D3, 0xE6D9, 0xE6E1, 0xE6E3, 0xE6E7, 0xF07DA, 0xE6F0, 0xE6F1, 0xE6F2,
];

// Build ICON_ALPHABET from code points (lazily initialized)
let _iconAlphabet: string[] | undefined = undefined;

function getIconAlphabet(): string[] {
  if (_iconAlphabet === undefined) {
    _iconAlphabet = [];
    for (let i = 0; i < ICON_CODE_POINTS.length; i++) {
      _iconAlphabet.push(String.fromCodePoint(ICON_CODE_POINTS[i]));
    }
  }
  return _iconAlphabet;
}

// Result of dividing a hex string by a decimal number
class HexDivResult {
  quotient: string = '';
  remainder: number = 0;
}

// Divide a hex string by a decimal divisor, returning quotient (hex string) and remainder.
// This simulates BigInt division: BigInt.parse(hex, 16) / divisor.
// Processes the hex string digit by digit (long division) to avoid BigInt.
function divideHexByDecimal(hexStr: string, divisor: number): HexDivResult {
  let remainder: number = 0;
  let quotient: string = '';
  for (let i = 0; i < hexStr.length; i++) {
    let digit: number = parseInt(hexStr[i], 16);
    let value: number = remainder * 16 + digit;
    let q: number = Math.floor(value / divisor);
    remainder = value % divisor;
    if (quotient.length > 0 || q > 0) {
      quotient += q.toString(16);
    }
  }
  let result: HexDivResult = new HexDivResult();
  result.quotient = quotient;
  result.remainder = remainder;
  return result;
}

// Convert combined fingerprint string to array of Material Icon characters.
// This matches the Dart reference implementation in fingerprint_alphabet.dart:
//   1. SHA-256(combined) → 64-char hex string
//   2. Take first 16 bytes (32 hex chars)
//   3. Compute result length = ceil(hexLen * 4 * ln(2) / ln(base))
//   4. Repeatedly divide by base, collect remainders (LSB-first), then reverse
export function toIcons(combined: string): Array<string> {
  let alphabet: string[] = getIconAlphabet();
  let base: number = alphabet.length; // 260

  // Step 1: SHA-256 hash of the combined fingerprint (64 hex chars)
  let hashHex: string = nativeComputeFingerprintHash(combined);

  // Step 2: Take first 16 bytes = 32 hex characters (matching Dart: digest.bytes.sublist(0, 16))
  let hexVal: string = hashHex.replace(new RegExp('[^0-9a-fA-F]', 'g'), '');
  if (hexVal.length === 0) {
    return [];
  }
  let truncated: string = hexVal.substring(0, Math.min(hexVal.length, 32));

  // Step 3: Calculate result length
  // Dart: (fingerprint.length * 4 * log(2) / log(alphabet.length)).ceil()
  // fingerprint.length = 32 hex chars, log(2) ≈ 0.693147, log(260) ≈ 5.5607
  // length = ceil(32 * 4 * 0.693147 / 5.5607) = ceil(15.96) = 16
  let length: number = Math.ceil(truncated.length * 4 * 0.693147 / Math.log(base));

  // Step 4: BigInt-style base conversion (simulated without BigInt)
  // Collect remainders by repeated division (LSB first), then fill from the end
  let remainders: Array<number> = [];
  let hexDigits: string = truncated;

  // Keep dividing until quotient becomes empty
  while (hexDigits.length > 0) {
    let divResult: HexDivResult = divideHexByDecimal(hexDigits, base);
    remainders.push(divResult.remainder);
    hexDigits = divResult.quotient;
  }

  // Build result array from the end (matching Dart: for i = length-1 down to 0)
  let icons: Array<string> = [];
  for (let i = 0; i < length; i++) {
    let idx: number = 0; // default to first icon (alphabet[0])
    let rIdx: number = remainders.length - 1 - i; // map from end of remainders
    if (rIdx >= 0) {
      idx = remainders[rIdx];
    }
    icons.push(alphabet[idx]);
  }

  return icons;
}

// Get the combined fingerprint string for text-mode display.
// The original LocalSend shows the sorted+joined fingerprint string directly,
// NOT the hex indices or hash. This matches:
//   Dart: SelectableText(fingerprint.combined)  // e.g. "abc123...def456..."
export function getCombinedFingerprint(localFingerprint: string, remoteFingerprint: string): string {
  let fingerprints: Array<string> = [localFingerprint, remoteFingerprint];
  fingerprints.sort();
  return fingerprints.join('');
}

