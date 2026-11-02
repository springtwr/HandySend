import { deviceInfo } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';

// 用于随机别名生成的形容词池
const ADJECTIVES_EN: Array<string> = [
  'happy', 'swift', 'bright', 'calm', 'bold', 'cool', 'cute', 'dapper',
  'deep', 'fast', 'fine', 'good', 'great', 'kind', 'light', 'nice',
  'pure', 'rare', 'rich', 'safe', 'shy', 'smart', 'soft', 'strong',
  'sweet', 'tall', 'warm', 'wild', 'wise', 'young', 'brave', 'clever',
  'gentle', 'lucky', 'quiet', 'steady', 'vivid', 'airy', 'blue', 'clear',
  'fair', 'free', 'grand', 'keen', 'neat', 'open', 'prime', 'real',
  'sharp', 'solid', 'tiny', 'true', 'quick', 'fresh', 'green', 'agile',
  'breezy', 'cheerful', 'cozy', 'fluffy'
];

const ANIMALS_EN: Array<string> = [
  'cat', 'dog', 'fox', 'bear', 'bird', 'deer', 'fish', 'frog',
  'hawk', 'lion', 'moose', 'panda', 'rabbit', 'shark', 'snake', 'tiger',
  'wolf', 'zebra', 'camel', 'eagle', 'heron', 'koala', 'lemur', 'otter',
  'penguin', 'raven', 'robin', 'seal', 'swan', 'whale', 'crane', 'dove',
  'finch', 'goose', 'ibis', 'jay', 'lynx', 'mole', 'newt', 'owl',
  'pug', 'quail', 'stoat', 'toad', 'puffin', 'wren', 'yak', 'lark',
  'bat', 'cow', 'elk', 'gecko', 'hare', 'impala', 'jackal', 'alpaca',
  'badger', 'beaver', 'bison', 'quokka'
];

// 中文形容词只取情绪、性格与气质类描述，避免「颜色 + 动物」等生硬搭配
const ADJECTIVES_ZH: Array<string> = [
  '快乐的', '欢快的', '开朗的', '活泼的', '调皮的', '乖巧的', '呆萌的', '萌萌的',
  '温柔的', '温暖的', '和煦的', '轻柔的', '安静的', '静谧的', '从容的', '悠然的',
  '自在的', '逍遥的', '悠闲的', '平静的', '淡定的', '自信的', '勇敢的', '大胆的',
  '机智的', '机灵的', '聪明的', '灵巧的', '敏捷的', '迅速的', '轻盈的', '优雅的',
  '帅气的', '酷酷的', '可爱的', '善良的', '真诚的', '友好的', '热情的', '勤奋的',
  '坚韧的', '浪漫的', '美好的', '幸运的', '清新的', '清爽的', '澄澈的', '明媚的',
  '闪亮的', '闪闪的', '柔和的', '明快的', '纯净的', '珍贵的', '灵动的', '聪慧的',
  '机敏的', '深邃的', '果敢的', '洒脱的'
];

// 中文动物名一律用双字及以上的完整称呼：单字「狗」「鸟」「鸭」等易被读成贬义，
// 统一改用「小狗」「小鸟」这类无歧义的复合词，避免生成「快乐的狗」式昵称。
const ANIMALS_ZH: Array<string> = [
  '猫', '小狗', '狐狸', '棕熊', '小鸟', '小鹿', '金鱼', '雄鹰',
  '狮子', '熊猫', '兔子', '老虎', '狼', '斑马', '天鹅', '鲸鱼',
  '企鹅', '海豹', '猫头鹰', '海豚', '考拉', '水獭', '仙鹤', '白鸽',
  '猎豹', '羚羊', '松鼠', '刺猬', '浣熊', '火烈鸟', '长颈鹿', '大象',
  '河马', '骆驼', '山羊', '绵羊', '小马', '雪豹', '虎鲸', '海狮',
  '章鱼', '水母', '海星', '锦鲤', '蝴蝶', '蜜蜂', '蜻蜓', '萤火虫',
  '瓢虫', '麻雀', '喜鹊', '黄鹂', '翠鸟', '燕子', '孔雀', '鹦鹉',
  '蜂鸟', '海鸥', '白鹭', '信天翁'
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
