import { existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import type { Browser } from 'playwright';
import { platformNames, rawCandidatesFor } from './config.js';
import type { Config, PlatformConfig, PlatformName, Rect, ShotStyle, Size } from './config.js';
import { ICONS } from './icons.js';

/** 注入页面的单张预览图数据：全部为可序列化的字符串与数字 */
interface InjectPayload {
  outputSize: Size;
  fontFamily: string;
  /** 条目风格：feature 时不加载设备框与截图，文案居中占满画布 */
  style: ShotStyle;
  /** 设备框图片地址；feature 风格为空串 */
  frameImage: string;
  screenArea: Rect;
  /** 屏幕开孔圆角半径（归一化到框图宽度，0 表示直角） */
  screenRadius: number;
  /** raw 截图地址；feature 风格为空串 */
  rawImage: string;
  title: string;
  subtitle: string;
  /** 特性图胶囊标签文案，空串隐藏 */
  tag: string;
  /** 特性图线性图标 SVG 字符串，空串隐藏 */
  iconSvg: string;
}

/** 页面布局度量结果：Node 侧据此断言布局正确性 */
interface LayoutMetrics {
  canvasWidth: number;
  canvasHeight: number;
  screenLeft: number;
  screenTop: number;
  screenWidth: number;
  screenHeight: number;
  expectedLeft: number;
  expectedTop: number;
  expectedWidth: number;
  expectedHeight: number;
}

/**
 * 在页面内注入单张预览图数据：填充文案与特性图元素、加载图片，并把归一化
 * screenArea 换算为设备框等比缩放后的精确像素位置。返回实际与期望的布局度量。
 */
async function injectShotData(data: InjectPayload): Promise<LayoutMetrics> {
  const canvas = document.querySelector('.canvas') as HTMLElement | null;
  const zone = document.querySelector('.frame-zone') as HTMLElement | null;
  const screen = document.querySelector('#screen') as HTMLElement | null;
  const frameImg = document.querySelector('#frame-img') as HTMLImageElement | null;
  const rawImg = document.querySelector('#raw-img') as HTMLImageElement | null;
  const titleEl = document.querySelector('#title') as HTMLElement | null;
  const subtitleEl = document.querySelector('#subtitle') as HTMLElement | null;
  const iconEl = document.querySelector('#feature-icon') as HTMLElement | null;
  const tagEl = document.querySelector('#feature-tag') as HTMLElement | null;
  const requiredNodes =
    '.canvas/.frame-zone/#screen/#frame-img/#raw-img/#title/#subtitle/#feature-icon/#feature-tag';
  if (!canvas || !zone || !screen || !frameImg || !rawImg || !titleEl || !subtitleEl || !iconEl || !tagEl) {
    throw new Error(`模板结构不完整：缺少必需节点（${requiredNodes}）`);
  }

  // 画布尺寸精确等于输出尺寸；字体可由语言配置覆盖
  canvas.style.width = `${data.outputSize.width}px`;
  canvas.style.height = `${data.outputSize.height}px`;
  if (data.fontFamily !== '') {
    canvas.style.fontFamily = data.fontFamily;
  }

  // 填充文案；未提供副标题时隐藏该节点
  titleEl.textContent = data.title;
  if (data.subtitle === '') {
    subtitleEl.style.display = 'none';
  } else {
    subtitleEl.style.display = '';
    subtitleEl.textContent = data.subtitle;
  }

  // 特性图元素：图标与胶囊标签仅 feature 风格由 CSS 显示，内容为空时隐藏节点
  if (data.iconSvg === '') {
    iconEl.style.display = 'none';
  } else {
    iconEl.style.display = '';
    iconEl.innerHTML = data.iconSvg;
  }
  if (data.tag === '') {
    tagEl.style.display = 'none';
  } else {
    tagEl.style.display = '';
    tagEl.textContent = data.tag;
  }

  const canvasRect = canvas.getBoundingClientRect();

  // 特性图风格：隐藏设备框区、放大文案居中占满画布；清空图片避免复用页面时上一张遗留
  if (data.style === 'feature') {
    canvas.classList.add('feature');
    frameImg.removeAttribute('src');
    rawImg.removeAttribute('src');
    return {
      canvasWidth: canvasRect.width,
      canvasHeight: canvasRect.height,
      screenLeft: 0,
      screenTop: 0,
      screenWidth: 0,
      screenHeight: 0,
      expectedLeft: 0,
      expectedTop: 0,
      expectedWidth: 0,
      expectedHeight: 0,
    };
  }

  // 截图风格：恢复框内嵌截图布局，加载设备框与 raw 截图，等待解码完成后再计算布局
  canvas.classList.remove('feature');
  frameImg.src = data.frameImage;
  rawImg.src = data.rawImage;
  await frameImg.decode();
  await rawImg.decode();

  const frameWidth = frameImg.naturalWidth;
  const frameHeight = frameImg.naturalHeight;
  if (frameWidth === 0 || frameHeight === 0) {
    throw new Error(`设备框图片无效：${data.frameImage}`);
  }

  // 设备框在框区内等比缩放（允许放大），缩放后居中
  const zoneRect = zone.getBoundingClientRect();
  const scale = Math.min(zoneRect.width / frameWidth, zoneRect.height / frameHeight);
  const displayWidth = frameWidth * scale;
  const displayHeight = frameHeight * scale;
  frameImg.style.width = `${displayWidth}px`;
  frameImg.style.height = `${displayHeight}px`;

  // 归一化 screenArea 乘以框图显示尺寸得到屏幕区域像素位置（相对画布）
  const area = data.screenArea;
  const expectedLeft = (zoneRect.left - canvasRect.left) + (zoneRect.width - displayWidth) / 2 + area.x * displayWidth;
  const expectedTop = (zoneRect.top - canvasRect.top) + (zoneRect.height - displayHeight) / 2 + area.y * displayHeight;
  const expectedWidth = area.width * displayWidth;
  const expectedHeight = area.height * displayHeight;

  screen.style.left = `${expectedLeft - (zoneRect.left - canvasRect.left)}px`;
  screen.style.top = `${expectedTop - (zoneRect.top - canvasRect.top)}px`;
  screen.style.width = `${expectedWidth}px`;
  screen.style.height = `${expectedHeight}px`;

  // 开孔圆角：归一化半径乘以框图显示宽度换算为像素；配合 overflow: hidden 裁掉截图直角
  screen.style.borderRadius = `${data.screenRadius * displayWidth}px`;

  // 读取实际布局，交由 Node 侧断言
  const screenRect = screen.getBoundingClientRect();
  return {
    canvasWidth: canvasRect.width,
    canvasHeight: canvasRect.height,
    screenLeft: screenRect.left - canvasRect.left,
    screenTop: screenRect.top - canvasRect.top,
    screenWidth: screenRect.width,
    screenHeight: screenRect.height,
    expectedLeft,
    expectedTop,
    expectedWidth,
    expectedHeight,
  };
}

/** 布局断言容差：亚像素舍入允许 1px 误差 */
const LAYOUT_TOLERANCE_PX = 1;

/** 预览图条目的标识：用于错误信息定位 */
function shotLabel(locale: string, featureId: string): string {
  return `${locale}/${featureId}`;
}

/** 断言页面布局度量符合预期，画布尺寸或屏幕区域偏差超容差即抛错 */
function assertMetrics(
  platform: PlatformName,
  locale: string,
  featureId: string,
  metrics: LayoutMetrics,
  outputSize: Size,
): void {
  const problems: string[] = [];
  if (
    Math.abs(metrics.canvasWidth - outputSize.width) > LAYOUT_TOLERANCE_PX ||
    Math.abs(metrics.canvasHeight - outputSize.height) > LAYOUT_TOLERANCE_PX
  ) {
    problems.push(
      `画布尺寸 ${metrics.canvasWidth}×${metrics.canvasHeight} 与输出尺寸 ${outputSize.width}×${outputSize.height} 不符`,
    );
  }
  const fields: Array<[string, number, number]> = [
    ['左侧位置', metrics.screenLeft, metrics.expectedLeft],
    ['顶部位置', metrics.screenTop, metrics.expectedTop],
    ['宽度', metrics.screenWidth, metrics.expectedWidth],
    ['高度', metrics.screenHeight, metrics.expectedHeight],
  ];
  for (const [label, actual, expected] of fields) {
    if (Math.abs(actual - expected) > LAYOUT_TOLERANCE_PX) {
      problems.push(`屏幕区域${label}实际 ${actual.toFixed(1)}px，期望 ${expected.toFixed(1)}px`);
    }
  }
  if (problems.length > 0) {
    throw new Error(`渲染布局校验失败（${platform} 端，条目 ${shotLabel(locale, featureId)}）：${problems.join('；')}`);
  }
}

/** 单张渲染产物与实际使用的风格 */
export interface RenderedShot {
  file: string;
  style: ShotStyle;
}

/** 单端单语言渲染结果 */
export interface PlatformRenderResult {
  locale: string;
  platform: PlatformName;
  shots: RenderedShot[];
}

/** 渲染单端单语言：视口设为输出尺寸，加载模板后逐张注入数据并截图导出 */
async function renderPlatform(
  browser: Browser,
  toolRoot: string,
  platform: PlatformName,
  locale: string,
  config: Config,
): Promise<PlatformRenderResult> {
  const platformConfig: PlatformConfig = config.platforms[platform];
  const outputSize = platformConfig.outputSize;
  const outputDir = resolve(toolRoot, 'output', platform, locale);
  mkdirSync(outputDir, { recursive: true });

  const context = await browser.newContext({
    viewport: { width: outputSize.width, height: outputSize.height },
    deviceScaleFactor: 1,
  });
  try {
    const page = await context.newPage();
    const templatePath = resolve(toolRoot, 'templates', `${platform}.html`);
    await page.goto(pathToFileURL(templatePath).href);

    const shots: RenderedShot[] = [];
    for (const featureId of config.shots) {
      const feature = config.features[featureId];
      const text = feature.text[locale];
      // 风格按 raw 截图是否存在自动推导：按候选顺序（png → jpg）取第一个实际存在的文件，
      // 命中即用图（screenshot），两者皆无才退化为文字特性图（feature）
      let rawAbsPath: string | undefined;
      for (const candidate of rawCandidatesFor(platform, locale, featureId)) {
        const abs = resolve(toolRoot, candidate);
        if (existsSync(abs)) {
          rawAbsPath = abs;
          break;
        }
      }
      const style: ShotStyle = rawAbsPath === undefined ? 'feature' : 'screenshot';
      const isFeature = style === 'feature';
      const payload: InjectPayload = {
        outputSize,
        fontFamily: config.localeConfigs[locale]?.fontFamily ?? '',
        style,
        frameImage: isFeature ? '' : pathToFileURL(resolve(toolRoot, platformConfig.frame.image)).href,
        screenArea: platformConfig.frame.screenArea,
        screenRadius: platformConfig.frame.radius ?? 0,
        rawImage: rawAbsPath === undefined ? '' : pathToFileURL(rawAbsPath).href,
        title: text.title,
        subtitle: text.subtitle ?? '',
        // 图标与胶囊标签仅在特性图下有意义；图标名经校验必在图标集中
        tag: isFeature ? text.tag ?? '' : '',
        iconSvg: isFeature && feature.icon !== undefined ? ICONS[feature.icon] : '',
      };
      const metrics = await page.evaluate(injectShotData, payload);
      assertMetrics(platform, locale, featureId, metrics, outputSize);

      const outputPath = resolve(outputDir, `${featureId}.png`);
      // clip 固定为整个输出尺寸，保证导出 PNG 尺寸精确等于 outputSize
      await page.screenshot({
        path: outputPath,
        clip: { x: 0, y: 0, width: outputSize.width, height: outputSize.height },
      });
      shots.push({ file: outputPath, style });
    }
    return { locale, platform, shots };
  } finally {
    await context.close();
  }
}

/**
 * 渲染入口：单浏览器实例按语言、端逐个渲染，任一张失败即抛错并由调用方统一处理。
 * @param locales 本次要生成的语言列表
 */
export async function renderAll(
  toolRoot: string,
  config: Config,
  locales: string[],
): Promise<PlatformRenderResult[]> {
  const browser = await chromium.launch();
  try {
    const results: PlatformRenderResult[] = [];
    for (const locale of locales) {
      for (const platform of platformNames()) {
        results.push(await renderPlatform(browser, toolRoot, platform, locale, config));
      }
    }
    return results;
  } finally {
    await browser.close();
  }
}
