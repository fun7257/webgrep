import { zh } from './i18n/zh.ts';
import { en } from './i18n/en.ts';

export type Locale = 'zh' | 'en';
export type LocaleMessages = typeof zh;

export const messages = {
  zh,
  en,
};
