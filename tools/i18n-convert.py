#!/usr/bin/env python3
"""One-shot i18n conversion for the MiMo TTS plugin.

- Rewrites menu/settings UI strings in the Lua sources to English msgids.
- Emits l10n/zh_CN/mimo_tts.po with the previous Chinese strings as
  translations (and l10n/mimo_tts.pot as the template).

The mapping table below is the single source of truth for this conversion:
english msgid -> chinese translation (= the previous source string).
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# english msgid -> chinese (current source strings)
MAP = {
    # plugin / menu titles
    "MiMo TTS Read-aloud": "MiMo TTS 语音听书",
    "Listen to the whole book (auto page turn)": "连续听书（自动翻页）",
    "Read current page": "朗读当前页",
    "Read selected text": "朗读选中文字",
    "Next segment": "下一段",
    "Previous segment": "上一段",
    "Stop reading": "停止朗读",
    "Test reading": "测试朗读",
    "Playback diagnostics…": "播放器诊断…",
    "Choose preset voice": "选择预置音色",
    "Choose preset voice (current: %1)": "选择预置音色（当前：%1）",
    "Voice changed to %1": "已切换音色：%1",
    # voices
    "MiMo default": "MiMo-默认",
    "Bingtang (Chinese, female)": "冰糖（中文·女）",
    "Jasmine (Chinese, female)": "茉莉（中文·女）",
    "Soda (Chinese, male)": "苏打（中文·男）",
    "Birch (Chinese, male)": "白桦（中文·男）",
    "Mia (English, female)": "Mia（英文·女）",
    "Chloe (English, female)": "Chloe（英文·女）",
    "Milo (English, male)": "Milo（英文·男）",
    "Dean (English, male)": "Dean（英文·男）",
    # toggles + feedback
    "Streaming synthesis (steadier for long texts)": "流式合成（长文本更稳）",
    "Streaming synthesis enabled": "已开启流式合成",
    "Streaming synthesis disabled": "已关闭流式合成",
    "Top menu icon": "顶部菜单图标",
    "Reading icon added to the top menu (reopen the menu to see it)": "已在顶部菜单添加听书图标（重新打开菜单可见）",
    "Reading icon removed from the top menu": "已移除顶部菜单听书图标",
    "Underline text while reading": "播放时给文字加下划线",
    "Reading underline enabled": "已开启朗读下划线",
    "Reading underline disabled": "已关闭朗读下划线",
    # menu action feedback
    "Please open a book first": "请先打开一本书",
    "No text selected (long-press to select text first)": "没有选中的文字（先长按选择文本）",
    "No readable text found": "没有提取到可朗读的文字",
    "Start reading (page %1, %2 segments)": "开始朗读（第 %1 页，共 %2 段）",
    "Reading stopped": "已停止朗读",
    "Finished reading": "听书结束",
    "Settings saved": "设置已保存",
    "Synthesizing test audio…": "正在合成测试音频…",
    "Clear audio cache": "清除语音缓存",
    "Delete all cached audio files?": "清除所有已缓存的语音文件？",
    "Delete": "清除",
    "Audio cache cleared": "语音缓存已清除",
    # settings dialogs
    "MiMo TTS API & model settings": "MiMo TTS 接口与模型设置",
    "MiMo TTS voice & style settings": "MiMo TTS 音色与风格设置",
    "MiMo TTS playback & segmentation settings": "MiMo TTS 播放与分段设置",
    "API & model settings…": "接口与模型设置…",
    "Voice & style settings…": "音色与风格设置…",
    "Playback & segmentation settings…": "播放与分段设置…",
    "API base URL": "API 地址",
    "API key": "API Key",
    "Required": "必填",
    "TTS model": "模型",
    "Audio format (mp3 / wav)": "音频格式（mp3 / wav）",
    "Style tag (e.g. gentle; optional)": "风格标签（如 温柔/磁性，可留空）",
    "Style prompt (natural-language instruction; optional)": "风格提示（自然语言指令，可留空）",
    "e.g. A warm audiobook narrator": "例如：温柔的有声书旁白",
    "Voice description (required for voice design)": "音色描述（音色设计模式必填）",
    "e.g. A mellow, deep middle-aged male voice": "例如：丝滑醇厚的中年男声",
    "Voice sample file (voice clone mode, mp3/wav)": "音色样本文件（音色复刻模式，mp3/wav）",
    "Speed (1.0 = normal)": "语速（1.0 为正常语速）",
    "Max segment length (longer ones are split)": "单句最大字数（超长句自动切分）",
    "Player command (empty = auto-detect)": "播放器命令（留空自动检测）",
    "Playback backend (auto/command/opensles)": "播放后端（auto/command/opensles）",
    "Cancel": "取消",
    "Save": "保存",
    # dispatcher action titles
    "MiMo TTS: start/stop reading": "MiMo TTS: 开始/停止听书",
    "MiMo TTS: read current page": "MiMo TTS: 朗读本页",
    "MiMo TTS: read the whole book": "MiMo TTS: 连续听书",
    "MiMo TTS: stop reading": "MiMo TTS: 停止朗读",
    "MiMo TTS: next segment": "MiMo TTS: 下一段",
    "MiMo TTS: previous segment": "MiMo TTS: 上一段",
}

def convert():
    changed = 0
    # longest first so that e.g. "清除语音缓存" wins over "清除"
    for en, zh in sorted(MAP.items(), key=lambda kv: -len(kv[1])):
        for name in ("main.lua", "_meta.lua"):
            path = os.path.join(ROOT, name)
            if not os.path.exists(path):
                continue
            s = open(path, encoding="utf-8").read()
            n = s.count('"%s"' % zh)
            if n:
                s = s.replace('"%s"' % zh, '"%s"' % en)
                open(path, "w", encoding="utf-8").write(s)
                changed += n
    print("rewrote %d string occurrences" % changed)

def write_po():
    os.makedirs(os.path.join(ROOT, "l10n", "zh_CN"), exist_ok=True)
    po = ['#: generated from the menu/settings UI strings',
          'msgid ""',
          'msgstr ""',
          '"Project-Id-Version: mimo-tts\\n"',
          '"Language: zh_CN\\n"',
          '"Content-Type: text/plain; charset=UTF-8\\n"',
          '"Content-Transfer-Encoding: 8bit\\n"',
          '"Plural-Forms: nplurals=1; plural=0;\\n"', '']
    for en, zh in sorted(MAP.items()):
        po.append('msgid "%s"' % en.replace('"', '\\"'))
        po.append('msgstr "%s"' % zh.replace('"', '\\"'))
        po.append('')
    open(os.path.join(ROOT, "l10n", "zh_CN", "mimo_tts.po"), "w", encoding="utf-8").write("\n".join(po))
    print("wrote l10n/zh_CN/mimo_tts.po (%d entries)" % len(MAP))

if __name__ == "__main__":
    convert()
    write_po()
