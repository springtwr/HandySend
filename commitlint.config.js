// commitlint 配置 — 匹配 COMMIT_CONVENTION.md 规范
// 安装：npm install -g @commitlint/cli @commitlint/config-conventional

/**
 * 自定义规则：正文非空行必须是"列表项"或"续行"两种形态之一
 * 列表项：必须以 "- " 顶格开头（"-" 前不允许任何空格）
 * 续行：必须以 4 个空格缩进开头（紧跟上一列表项的换行内容）
 * 对应 COMMIT_CONVENTION.md 中"多项内容用 - 列表"的要求
 */
const bodyLinesStartWithDash = {
  /** @param {{ body: string }} commit */
  check({ body }) {
    if (!body) {
      // 正文为空，不检查
      return [true];
    }
    const lines = body.split('\n');
    const violations = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // 空行、纯空格行跳过
      if (line.trim() === '') {
        continue;
      }
      // 去掉前导空格后判断是否为列表项
      const trimmed = line.trimStart();
      if (trimmed.startsWith('- ')) {
        // 是列表项——但 "-" 前不能有任何空白（空格/tab），否则视为非法缩进
        if (line !== trimmed) {
          violations.push(i + 1);
        }
        continue;
      }
      // 非列表项行必须是 4 空格缩进的续行
      if (!line.startsWith('    ')) {
        violations.push(i + 1);
      }
    }
    if (violations.length > 0) {
      return [
        false,
        `正文第 ${violations.join(', ')} 行格式错误：列表项必须以 "- " 顶格开头（"-" 前不能有空格），续行必须以 4 个空格缩进`,
      ];
    }
    return [true];
  },
};

export default {
  extends: ['@commitlint/config-conventional'],
  plugins: [
    {
      rules: {
        'body-lines-start-with-dash': bodyLinesStartWithDash.check,
      },
    },
  ],
  rules: {
    // type 必须使用 COMMIT_CONVENTION.md 中定义的类型
    'type-enum': [
      2,
      'always',
      [
        'feat',
        'fix',
        'docs',
        'style',
        'refactor',
        'perf',
        'test',
        'build',
        'ci',
        'chore',
        'release',
        'revert',
      ],
    ],
    // scope 推荐使用项目定义的范围（不强制，因为文档说"不是封闭列表"）
    'scope-enum': [
      1,
      'always',
      [
        'transfer',
        'discovery',
        'settings',
        'native',
        'bridge',
        'ui',
        'log',
        'build',
      ],
    ],
    // 标题不超过 50 个字符（COMMIT_CONVENTION.md 要求，按字符计数，1 中文 = 1）
    'subject-max-length': [2, 'always', 50],
    // 标题不以句号结尾
    'subject-full-stop': [2, 'never', '.。'],
    // 标题不为空
    'subject-empty': [2, 'never'],
    // type 不为空
    'type-empty': [2, 'never'],
    // scope 小写
    'scope-case': [2, 'always', 'lower-case'],
    // type 小写
    'type-case': [2, 'always', 'lower-case'],
    // 正文每行不超过 72 个字符
    'body-max-line-length': [2, 'always', 72],
    // footer 每行不超过 72 个字符
    'footer-max-line-length': [2, 'always', 72],
    // 正文非空行必须以 "- " 开头（自定义规则）
    'body-lines-start-with-dash': [2, 'always'],
  },
};
