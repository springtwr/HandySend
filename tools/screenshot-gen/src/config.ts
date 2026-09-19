import { readFileSync } from 'node:fs';

/** 屏幕区域矩形：归一化坐标（0–1），相对设备框图像尺寸 */
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 输出画布像素尺寸 */
export interface Size {
  width: number;
  height: number;
}

/** 预览图风格：screenshot 为框内嵌截图，feature 为纯文案特性图（无框无截图）。
 *  风格不通过配置指定，渲染时按 raw 截图是否存在自动推导 */
export type ShotStyle = 'screenshot' | 'feature';

/** 特性的单语言文案 */
export interface FeatureText {
  title: string;
  /** 副标题（可选；空串视为未提供） */
  subtitle?: string;
  /** 特性图胶囊标签（可选，仅 feature 风格渲染；空串视为未提供） */
  tag?: string;
}

/** 特性条目：多语言文案与可选图标名 */
export interface FeatureConfig {
  /** 图标名（src/icons.ts 中定义），可选 */
  icon?: string;
  /** 各语言文案，键为语言代码，必须覆盖 locales 声明的全部语言 */
  text: Record<string, FeatureText>;
}

/** 设备框配置：素材路径与框内屏幕区域 */
export interface FrameConfig {
  /** 框素材路径（相对工具目录） */
  image: string;
  screenArea: Rect;
  /** 屏幕开孔圆角半径（归一化到框图宽度，0–1；缺省 0 表示直角开孔） */
  radius?: number;
}

/** 单端配置 */
export interface PlatformConfig {
  outputSize: Size;
  frame: FrameConfig;
}

/** 三端名称 */
export type PlatformName = 'phone' | 'tablet' | 'pc';

/** 单语言配置 */
export interface LocaleConfig {
  /** 可选 CSS font-family 值，覆盖模板默认字体栈 */
  fontFamily?: string;
}

/** 顶层配置 */
export interface Config {
  /** 语言代码列表（如 zh_CN），至少一个 */
  locales: string[];
  /** 各语言配置，键须为 locales 中声明的语言 */
  localeConfigs: Record<string, LocaleConfig>;
  /** 特性集，键为特性 id */
  features: Record<string, FeatureConfig>;
  /** 预览图特性 id 有序列表，三端共用；顺序即输出顺序 */
  shots: string[];
  platforms: Record<PlatformName, PlatformConfig>;
}

/** 配置错误：message 中包含具体 JSON 路径，便于定位 */
export class ConfigError extends Error {}

const PLATFORM_NAMES: PlatformName[] = ['phone', 'tablet', 'pc'];

/**
 * 路径成分（语言代码 / 特性 id）约束：仅字母、数字、下划线、连字符。
 * 二者会拼入文件路径，不允许斜杠与点号以避免路径注入。
 */
const NAME_PATTERN = /^[A-Za-z0-9_-]+$/;

/**
 * 截图风格条目的 raw 截图候选路径（按优先级有序）：先 .png 后 .jpg，顺序即识别顺序。
 * 渲染时按序取第一个实际存在的文件作为截图底图；两者皆不存在则退化为特性图。
 */
export function rawCandidatesFor(platform: PlatformName, locale: string, feature: string): string[] {
  return [
    `raw/${platform}/${locale}/${feature}.png`,
    `raw/${platform}/${locale}/${feature}.jpg`,
  ];
}

/** 输出文件约定路径：output/<端>/<语言>/<特性>.png */
export function outputPathFor(platform: PlatformName, locale: string, feature: string): string {
  return `output/${platform}/${locale}/${feature}.png`;
}

/** 判断值是否为普通对象（非 null、非数组） */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** 在指定 JSON 路径处抛出配置错误 */
function fail(path: string, message: string): never {
  throw new ConfigError(`配置错误（config.json 的 ${path}）：${message}`);
}

/** 断言值为普通对象，否则按 path 报错 */
function expectRecord(value: unknown, path: string): Record<string, unknown> {
  if (!isRecord(value)) {
    fail(path, '应为对象');
  }
  return value;
}

/** 读取必填字段，缺失时按 path 报错 */
function expectField(obj: Record<string, unknown>, key: string, path: string): unknown {
  if (!(key in obj)) {
    fail(path, '字段缺失');
  }
  return obj[key];
}

/** 断言值为正整数（像素尺寸），否则按 path 报错 */
function expectPositiveInt(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value <= 0) {
    fail(path, '应为正整数');
  }
  return value;
}

/** 断言值为非空字符串，否则按 path 报错 */
function expectNonEmptyString(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(path, '应为非空字符串');
  }
  return value;
}

/** 断言值为 0–1 之间的数值（归一化坐标），否则按 path 报错 */
function expectUnitValue(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) {
    fail(path, '应为 0–1 之间的数值');
  }
  return value;
}

/** 校验语言代码列表：非空、格式合法、无重复 */
function validateLocales(value: unknown): string[] {
  const path = 'locales';
  if (!Array.isArray(value) || value.length === 0) {
    fail(path, '应为非空数组（至少一种语言）');
  }
  const locales = value.map((item, index) => {
    const locale = expectNonEmptyString(item, `${path}[${index}]`);
    if (!NAME_PATTERN.test(locale)) {
      fail(`${path}[${index}]`, '语言代码仅允许字母、数字、下划线、连字符');
    }
    return locale;
  });
  const duplicated = locales.find((locale, index) => locales.indexOf(locale) !== index);
  if (duplicated !== undefined) {
    fail(path, `语言代码重复：${duplicated}`);
  }
  return locales;
}

/** 校验单语言配置（目前仅字体） */
function validateLocaleConfig(locale: string, value: unknown): LocaleConfig {
  const path = `localeConfigs.${locale}`;
  const record = expectRecord(value, path);
  const config: LocaleConfig = {};
  if ('fontFamily' in record) {
    config.fontFamily = expectNonEmptyString(record.fontFamily, `${path}.fontFamily`);
  }
  return config;
}

/** 校验单个特性的单语言文案 */
function validateFeatureText(featureId: string, locale: string, value: unknown): FeatureText {
  const path = `features.${featureId}.text.${locale}`;
  const record = expectRecord(value, path);
  const text: FeatureText = {
    title: expectNonEmptyString(expectField(record, 'title', `${path}.title`), `${path}.title`),
  };
  if ('subtitle' in record) {
    const subtitle = record.subtitle;
    if (typeof subtitle !== 'string') {
      fail(`${path}.subtitle`, '应为字符串');
    }
    // 空字符串视为未提供副标题
    if (subtitle !== '') {
      text.subtitle = subtitle;
    }
  }
  if ('tag' in record) {
    const tag = record.tag;
    if (typeof tag !== 'string') {
      fail(`${path}.tag`, '应为字符串');
    }
    // 空字符串视为未提供胶囊标签
    if (tag !== '') {
      text.tag = tag;
    }
  }
  return text;
}

/** 校验单个特性条目：文案须覆盖全部语言，图标名可选 */
function validateFeature(id: string, value: unknown, locales: string[]): FeatureConfig {
  const path = `features.${id}`;
  const record = expectRecord(value, path);

  const feature: FeatureConfig = {
    text: {},
  };
  if ('icon' in record) {
    feature.icon = expectNonEmptyString(record.icon, `${path}.icon`);
  }

  const textRecord = expectRecord(expectField(record, 'text', `${path}.text`), `${path}.text`);
  // 文案必须覆盖全部声明语言，缺一即报错
  for (const locale of locales) {
    feature.text[locale] = validateFeatureText(
      id,
      locale,
      expectField(textRecord, locale, `${path}.text.${locale}`),
    );
  }
  // 不允许声明语言之外的多余文案键，避免语言代码拼写错误被静默忽略
  for (const key of Object.keys(textRecord)) {
    if (!locales.includes(key)) {
      fail(`${path}.text.${key}`, '未在 locales 中声明的语言（请检查语言代码拼写或补充 locales）');
    }
  }
  return feature;
}

/** 校验预览图序列：特性 id 须存在且不得重复（重复会导致输出文件名冲突） */
function validateShots(value: unknown, features: Record<string, FeatureConfig>): string[] {
  const path = 'shots';
  if (!Array.isArray(value) || value.length === 0) {
    fail(path, '应为非空数组（至少一条预览图条目）');
  }
  const shots = value.map((item, index) => {
    const featureId = expectNonEmptyString(item, `${path}[${index}]`);
    if (!(featureId in features)) {
      fail(`${path}[${index}]`, `引用了不存在的特性：${featureId}（features 中未定义）`);
    }
    return featureId;
  });
  const duplicated = shots.find((id, index) => shots.indexOf(id) !== index);
  if (duplicated !== undefined) {
    fail(path, `特性引用重复：${duplicated}（同一特性只能出现一次，否则输出文件名冲突）`);
  }
  return shots;
}

/** 校验单端配置 */
function validatePlatform(platform: PlatformName, value: unknown): PlatformConfig {
  const rootPath = `platforms.${platform}`;
  const root = expectRecord(value, rootPath);

  const sizePath = `${rootPath}.outputSize`;
  const sizeRecord = expectRecord(expectField(root, 'outputSize', sizePath), sizePath);
  const outputSize: Size = {
    width: expectPositiveInt(expectField(sizeRecord, 'width', `${sizePath}.width`), `${sizePath}.width`),
    height: expectPositiveInt(expectField(sizeRecord, 'height', `${sizePath}.height`), `${sizePath}.height`),
  };

  const framePath = `${rootPath}.frame`;
  const frameRecord = expectRecord(expectField(root, 'frame', framePath), framePath);
  const image = expectNonEmptyString(
    expectField(frameRecord, 'image', `${framePath}.image`),
    `${framePath}.image`,
  );

  const areaPath = `${framePath}.screenArea`;
  const areaRecord = expectRecord(expectField(frameRecord, 'screenArea', areaPath), areaPath);
  const screenArea: Rect = {
    x: expectUnitValue(expectField(areaRecord, 'x', `${areaPath}.x`), `${areaPath}.x`),
    y: expectUnitValue(expectField(areaRecord, 'y', `${areaPath}.y`), `${areaPath}.y`),
    width: expectUnitValue(expectField(areaRecord, 'width', `${areaPath}.width`), `${areaPath}.width`),
    height: expectUnitValue(expectField(areaRecord, 'height', `${areaPath}.height`), `${areaPath}.height`),
  };
  // 屏幕区域不得越出设备框图像
  if (screenArea.x + screenArea.width > 1 + 1e-9) {
    fail(areaPath, 'x + width 超出 1，屏幕区域越出设备框');
  }
  if (screenArea.y + screenArea.height > 1 + 1e-9) {
    fail(areaPath, 'y + height 超出 1，屏幕区域越出设备框');
  }

  // 开孔圆角半径为可选字段，归一化到框图宽度
  let radius: number | undefined;
  if ('radius' in frameRecord) {
    radius = expectUnitValue(frameRecord.radius, `${framePath}.radius`);
  }

  return {
    outputSize,
    frame: radius !== undefined ? { image, screenArea, radius } : { image, screenArea },
  };
}

/** 将 JSON 解析错误信息补充为行/列位置 */
function describeParseError(text: string, err: unknown): string {
  const message = err instanceof Error ? err.message : String(err);
  // 新版 V8 的报错已自带行列信息，直接使用
  if (message.includes('line')) {
    return message;
  }
  // 旧格式仅含字节偏移，手工换算为行/列
  const match = message.match(/position (\d+)/);
  if (!match) {
    return message;
  }
  const position = Number(match[1]);
  const before = text.slice(0, position);
  const line = before.split('\n').length;
  const column = position - before.lastIndexOf('\n');
  return `${message}（第 ${line} 行第 ${column} 列附近）`;
}

/** 加载并校验配置文件，返回强类型 Config；任何结构问题均抛出 ConfigError */
export function loadConfig(configPath: string): Config {
  let text: string;
  try {
    text = readFileSync(configPath, 'utf8');
  } catch {
    throw new ConfigError(`无法读取配置文件：${configPath}`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new ConfigError(`config.json 解析失败：${describeParseError(text, err)}`);
  }

  const root = expectRecord(parsed, '(根对象)');
  const locales = validateLocales(expectField(root, 'locales', 'locales'));

  // 各语言配置：仅接受已声明的语言作为键
  const localeConfigsValue = expectRecord(expectField(root, 'localeConfigs', 'localeConfigs'), 'localeConfigs');
  const localeConfigs: Record<string, LocaleConfig> = {};
  for (const key of Object.keys(localeConfigsValue)) {
    if (!locales.includes(key)) {
      fail(`localeConfigs.${key}`, '未在 locales 中声明的语言（请检查语言代码拼写或补充 locales）');
    }
    localeConfigs[key] = validateLocaleConfig(key, localeConfigsValue[key]);
  }

  // 特性集：非空对象，键为特性 id
  const featuresValue = expectRecord(expectField(root, 'features', 'features'), 'features');
  const featureIds = Object.keys(featuresValue);
  if (featureIds.length === 0) {
    fail('features', '应为非空对象（至少一个特性）');
  }
  const features: Record<string, FeatureConfig> = {};
  for (const id of featureIds) {
    if (!NAME_PATTERN.test(id)) {
      fail(`features.${id}`, '特性 id 仅允许字母、数字、下划线、连字符');
    }
    features[id] = validateFeature(id, featuresValue[id], locales);
  }

  const shots = validateShots(expectField(root, 'shots', 'shots'), features);

  const platformsValue = expectRecord(expectField(root, 'platforms', 'platforms'), 'platforms');

  return {
    locales,
    localeConfigs,
    features,
    shots,
    platforms: {
      phone: validatePlatform('phone', expectField(platformsValue, 'phone', 'platforms.phone')),
      tablet: validatePlatform('tablet', expectField(platformsValue, 'tablet', 'platforms.tablet')),
      pc: validatePlatform('pc', expectField(platformsValue, 'pc', 'platforms.pc')),
    },
  };
}

/** 三端名称列表（渲染与校验共用的固定顺序） */
export function platformNames(): PlatformName[] {
  return [...PLATFORM_NAMES];
}
