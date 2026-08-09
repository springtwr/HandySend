// FingerprintIcons: Maps CombinedFingerprint hex to Emoji sequence
// Uses a curated subset of ~200 Unicode Emoji as the "alphabet"
// for converting a large hex integer into a visual icon grid.

const EMOJI_ALPHABET: Array<string> = [
  '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
  '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔',
  '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🦇', '🐺',
  '🐗', '🐴', '🦄', '🐝', '🪱', '🐛', '🦋', '🐌',
  '🐞', '🐜', '🪰', '🪲', '🪳', '🦟', '🦗', '🕷',
  '🐢', '🐍', '🦎', '🦖', '🦕', '🐙', '🦑', '🦐',
  '🦞', '🦀', '🐡', '🐠', '🐟', '🐬', '🐳', '🐋',
  '🦈', '🐊', '🐅', '🐆', '🦓', '🦍', '🦧', '🐘',
  '🦛', '🦏', '🐪', '🐫', '🦒', '🦘', '🦬', '🐃',
  '🐂', '🐄', '🐎', '🐖', '🐏', '🐑', '🦙', '🐐',
  '🦌', '🐕', '🐩', '🦮', '🐈', '🪶', '🐓', '🦃',
  '🦤', '🦚', '🦜', '🦢', '🦩', '🕊', '🐇', '🦝',
  '🦨', '🦡', '🦫', '🦦', '🦥', '🐁', '🐀', '🐿',
  '🦔', '🌸', '🌺', '🌻', '🌹', '🌷', '🌱', '🌲',
  '🌳', '🌴', '🌵', '🍀', '🍁', '🍂', '🍃', '🍎',
  '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐',
  '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅',
  '🥑', '🥦', '🥬', '🥒', '🌶', '🫑', '🌽', '🥕',
  '🫒', '🧄', '🧅', '🥔', '🍠', '🫘', '🥐', '🥖',
  '🍞', '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇',
  '🥓', '🥩', '🍗', '🍖', '🌭', '🍔', '🍟', '🍕',
  '🫓', '🥪', '🥙', '🧆', '🌮', '🌯', '🫔', '🥗',
  '🫕', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟',
  '🦪', '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮'
];

// Convert hex string to array of emoji icons (about 16 icons, 4-column grid)
export function toIcons(combined: string): Array<string> {
  let base: number = EMOJI_ALPHABET.length;
  let hexVal: string = combined.replace(/[^0-9a-fA-F]/g, '');
  if (hexVal.length === 0) {
    return [];
  }
  // Take first 16 hex characters (64 bits worth)
  let truncated: string = hexVal.substring(0, Math.min(hexVal.length, 16));
  let num = BigInt('0x' + truncated);
  let icons: Array<string> = [];
  let count = 16;
  let bigBase = BigInt(base);
  for (let i = 0; i < count; i++) {
    let mod = Number(num % bigBase);
    icons.push(EMOJI_ALPHABET[mod]);
    num = num / bigBase;
    if (num === BigInt(0)) {
      break;
    }
  }
  // Pad to at least 8 icons for visual grid
  while (icons.length < 8) {
    icons.push(EMOJI_ALPHABET[0]);
  }
  return icons;
}

// Convert emoji icons back to hex (for verification display)
export function toHex(icons: Array<string>): string {
  let result: string = '';
  for (let i = 0; i < icons.length; i++) {
    let idx = EMOJI_ALPHABET.indexOf(icons[i]);
    if (idx >= 0) {
      result += idx.toString(16).padStart(2, '0');
    } else {
      result += '00';
    }
  }
  return result;
}

export function getEmojiAlphabetSize(): number {
  return EMOJI_ALPHABET.length;
}
