import { deviceInfo } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';

// 用于随机别名生成的形容词池
const ADJECTIVES_EN: Array<string> = [
  'happy', 'swift', 'bright', 'calm', 'bold', 'cool', 'cute', 'dark',
  'deep', 'fast', 'fine', 'good', 'great', 'kind', 'light', 'nice',
  'pure', 'rare', 'rich', 'safe', 'shy', 'smart', 'soft', 'strong',
  'sweet', 'tall', 'warm', 'wild', 'wise', 'young', 'brave', 'clever',
  'gentle', 'lucky', 'quiet', 'steady', 'vivid', 'airy', 'blue', 'clear',
  'fair', 'free', 'grand', 'keen', 'neat', 'open', 'prime', 'real',
  'sharp', 'solid', 'tiny', 'true', 'warm', 'quick', 'fresh', 'green'
];

const ANIMALS_EN: Array<string> = [
  'cat', 'dog', 'fox', 'bear', 'bird', 'deer', 'fish', 'frog',
  'hawk', 'lion', 'moose', 'panda', 'rabbit', 'shark', 'snake', 'tiger',
  'wolf', 'zebra', 'camel', 'eagle', 'heron', 'koala', 'lemur', 'otter',
  'penguin', 'raven', 'robin', 'seal', 'swan', 'whale', 'crane', 'dove',
  'finch', 'goose', 'ibis', 'jay', 'lynx', 'mole', 'newt', 'owl',
  'pug', 'quail', 'stoat', 'toad', 'viper', 'wren', 'yak', 'ape',
  'bat', 'cow', 'dove', 'elk', 'gnu', 'hare', 'impala', 'jackal'
];

const ADJECTIVES_ZH: Array<string> = [
  '快乐的', '迅速的', '明亮的', '平静的', '大胆的', '酷酷的', '可爱的', '深邃的',
  '敏捷的', '美好的', '善良的', '轻盈的', '温柔的', '纯净的', '珍贵的', '温暖的',
  '勇敢的', '聪明的', '幸运的', '安静的', '坚定的', '生动的', '自由的', '伟大的',
  '灵巧的', '优雅的', '闪亮的', '活泼的', '勤奋的', '浪漫的'
];

const ANIMALS_ZH: Array<string> = [
  '猫', '狗', '狐狸', '熊', '鸟', '鹿', '鱼', '鹰',
  '狮子', '熊猫', '兔子', '老虎', '狼', '斑马', '天鹅', '鲸鱼',
  '企鹅', '海豹', '猫头鹰', '海豚', '考拉', '水獭', '仙鹤', '白鸽',
  '猎豹', '羚羊', '松鼠', '刺猬', '浣熊', '火烈鸟'
];

function randomItem(arr: Array<string>): string {
  let idx = Math.floor(Math.random() * arr.length);
  return arr[idx];
}

export function generateAlias(): string {
  // 使用感知语言环境的别名生成
  try {
    let preferredLang = i18n.System.getAppPreferredLanguage();
    if (preferredLang.startsWith('zh')) {
      return generateAliasZh();
    }
  } catch (_e) {
    // 回退到英语
  }
  let adj = randomItem(ADJECTIVES_EN);
  let animal = randomItem(ANIMALS_EN);
  return adj + '-' + animal;
}

function generateAliasZh(): string {
  let adj = randomItem(ADJECTIVES_ZH);
  let animal = randomItem(ANIMALS_ZH);
  return adj + animal;
}

export function getSystemDeviceName(): string {
  // 优先返回设备市场名称（设置中显示的设备名），取不到时回退到厂商+产品型号
  let marketName: string = deviceInfo.marketName;
  if (marketName.length > 0) {
    return marketName;
  }
  return deviceInfo.manufacture + ' ' + deviceInfo.productModel;
}
