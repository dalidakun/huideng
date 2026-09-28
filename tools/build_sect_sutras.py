#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build assets/sect_sutras/manifest.json: an index of the 8 Chinese Buddhist
schools' core sutras, resolved against the existing sutra corpus.

The index is zero-copy on purpose: it stores only ids, titles and the canonical
asset path `assets/sutras_ascii/<vol>/<ID>.txt`. No .txt is ever duplicated, so
the index can never drift away from `assets/sutras_ascii/` (the GitHub download
source) or `assets/sutras_edited/` (the admin re-typeset version, which takes
priority when reading).

Usage: python tools/build_sect_sutras.py
"""
import json
import re
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASCII_ROOT = ROOT / "assets" / "sutras_ascii"
CATALOG = ROOT / "assets" / "sutras_catalog.json"
OUT_DIR = ROOT / "assets" / "sect_sutras"
OUT_JSON = OUT_DIR / "manifest.json"
OUT_MD = OUT_DIR / "README.md"

ID_RE = re.compile(r"T\d{2}n\d{4}[A-Za-z]?_\d{3}")
# CBETA puts editorial marks inline with the text, both half- and full-width:
# "[＊]于阗国三[＊]藏" / "大方广佛华严经卷[＊]第十五". Strip them, otherwise the
# part-title regex never matches those volumes.
CBETA_MARK_RE = re.compile(r"\[[*＊]\s*\]")
# "卷下一" / "卷上二" -> "卷下" / "卷上": CBETA writes the ordinal as a trailing
# numeral after 上/中/下.
PART_ORDINAL_RE = re.compile(r"^(卷[上中下])[一二三四五六七八九十]+$")
# A trailing CBETA editorial note, e.g. "卷下一(注撰非少立名标显)" -> "卷下", or an
# alias note, e.g. "首楞严经卷第二(一名中印度那兰陀大道场经)" -> "卷第二".
EDITORIAL_TAIL_RE = re.compile(
    r"[（(][^）)]*(?:撰|著述|标显|作者|非|一名|别名|亦名)[^）)]*[）)]\s*$"
)
# Part title carried at the head of a volume file, always starting with the
# sutra's own name: "中论卷第一", "摩诃止观卷第一(上)", "佛说无量寿经卷上",
# "四分律删繁补阙行事钞卷下一(注撰…)", "十二门论品目", "广百论本一卷".
PART_RE = re.compile(
    r"^(?P<base>.+?)(?P<part>卷第[一二三四五六七八九十百零]+|卷[上中下]"
    r"|序|目录|品目|[一二三四五六七八九十]+卷)"
    r"(?P<rest>.*)$"
)
# A part title that carries a different opening name, e.g.
# "大周新译大方广佛华严经序" (T279 vol 1) or "四分律序".
TRAILING_PART_RE = re.compile(r"(?P<part>卷第[一二三四五六七八九十百零]+|卷[上中下]|序|目录)$")
# Trailing volume label on the catalog title, e.g. "中论卷第一" -> "中论",
# "百论卷下" -> "百论", "佛说无量寿经卷上" -> "佛说无量寿经".
TITLE_VOL_RE = re.compile(
    r"\s*(?:卷第[一二三四五六七八九十百零]+|卷[上中下][一二三四五六七八九十]*)$"
)

# SECT_SPEC / GATE_SPEC are three-level trees:
#     menu (宗门 or 法门) -> core sutra (the "folder") -> edition (one translator
#     or one recension) -> volumes (resolved from the corpus).
#
# Grouping translations of the same sutra under one folder is what the UI shows,
# so a group must be a single canonical sutra, not a loose theme.
#
# Fields per menu:
#   key        short ascii slug; the manifest key becomes "<kind>:<key>"
#   name       宗门/法门名
#   desc       列表行副标题
#   groups     core sutras
#
# Fields per group:
#   name       经名 as the user-facing curriculum names it (the folder)
#   note       optional caveat (substitute text, missing volume, ...)
#   editions   one entry per translator / recension
#
# Fields per edition:
#   label      shown as "<group>·<label>", e.g. "金刚经·鸠摩罗什译"
#   cbeta      CBETA n-number, used for display
#   ids        prefix matched against catalog ids, so every volume file is picked up
#   files      exact ids, for a 品/章 that is NOT a standalone file; replaces ids
#   volRange   [lo, hi] keep only these CBETA ordinals, for slicing one sutra
#              into several 卷本 (大般若的十六会)
#   partFromVol take the volume label from the CBETA ordinal instead of the file
#              head; needed where many files share a head label (大般若的会序)
#   translator authoritative byline/attribution (never scraped from the text)
#   base       optional override when the catalog title is truncated
#   note       optional caveat specific to this edition
SECT_SPEC = [
    {
        "name": "禅宗",
        "key": "zen",
        "desc": "以禅修、参悟为核心",
        "groups": [
            {
                "name": "金刚经",
                "note": "六译本并收，以鸠摩罗什本为通行本",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T235", "ids": ["T08n0235"],
                     "translator": "姚秦 鸠摩罗什"},
                    {"label": "菩提流支译", "cbeta": "T236a", "ids": ["T08n0236a"],
                     "translator": "元魏 菩提流支"},
                    {"label": "菩提留支译", "cbeta": "T236b", "ids": ["T08n0236b"],
                     "translator": "元魏 菩提留支"},
                    {"label": "真谛译", "cbeta": "T237", "ids": ["T08n0237"],
                     "translator": "陈 真谛"},
                    {"label": "笈多译", "cbeta": "T238", "ids": ["T08n0238"],
                     "translator": "隋 笈多"},
                    {"label": "义净译", "cbeta": "T239", "ids": ["T08n0239"],
                     "translator": "唐 义净"},
                ],
            },
            {
                "name": "楞伽经",
                "note": "三译本并收；阿跋多罗宝经本为宋元明通行本",
                "editions": [
                    {"label": "菩提流支译", "cbeta": "T670", "ids": ["T16n0670"],
                     "translator": "元魏 菩提流支"},
                    {"label": "菩提留支译", "cbeta": "T671", "ids": ["T16n0671"],
                     "translator": "元魏 菩提留支"},
                    {"label": "实叉难陀译", "cbeta": "T672", "ids": ["T16n0672"],
                     "translator": "唐 实叉难陀"},
                ],
            },
            {
                "name": "六祖坛经",
                "editions": [
                    {"label": "宗宝本", "cbeta": "T2008", "ids": ["T48n2008"],
                     "translator": "元 宗宝本"},
                ],
            },
        ],
    },
    {
        "name": "净土宗",
        "key": "jingtu",
        "desc": "以信愿念佛，往生净土为主",
        "groups": [
            {
                "name": "无量寿经",
                "editions": [
                    {"label": "康僧铠译", "cbeta": "T360", "ids": ["T12n0360"],
                     "translator": "曹魏 康僧铠"},
                ],
            },
            {
                "name": "观无量寿经",
                "editions": [
                    {"label": "康僧铠译", "cbeta": "T365", "ids": ["T12n0365"],
                     "translator": "曹魏 康僧铠"},
                ],
            },
            {
                "name": "阿弥陀经",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T366", "ids": ["T12n0366"],
                     "translator": "姚秦 鸠摩罗什"},
                ],
            },
            {
                "name": "往生论",
                "note": "原书（世亲造·菩提流支译）全库缺失，此以唐·迦才《净土论》九章代之",
                "editions": [
                    {"label": "迦才撰", "cbeta": "T1963", "ids": ["T47n1963"],
                     "translator": "唐 迦才"},
                ],
            },
        ],
    },
    {
        "name": "天台宗",
        "key": "tiantai",
        "desc": "教观并重，止观双修",
        "groups": [
            {
                "name": "妙法莲华经",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T262", "ids": ["T09n0262"],
                     "translator": "姚秦 鸠摩罗什"},
                ],
            },
            {
                "name": "摩诃止观",
                "note": "CBETA 分上下共 20 卷；本库每文件打包上下两半，故按文件计 10 卷",
                "editions": [
                    {"label": "灌顶记", "cbeta": "T1911", "ids": ["T46n1911"],
                     "translator": "隋 天台智者大师说·灌顶记"},
                ],
            },
        ],
    },
    {
        "name": "华严宗",
        "key": "huayan",
        "desc": "以华严经为根本，圆融无碍",
        "groups": [
            {
                "name": "华严经",
                "note": "三译全本并收，另收两种单品",
                "editions": [
                    {"label": "实叉难陀译（八十卷本）", "cbeta": "T279",
                     "ids": ["T10n0279"], "translator": "唐 实叉难陀"},
                    {"label": "佛驮跋陀罗译（六十卷本）", "cbeta": "T278",
                     "ids": ["T09n0278"], "translator": "东晋 佛驮跋陀罗"},
                    {"label": "般若译（四十卷本）", "cbeta": "T293",
                     "ids": ["T10n0293"], "translator": "罽宾 般若"},
                    {"label": "地婆诃罗译（入法界品）", "cbeta": "T295",
                     "ids": ["T10n0295"], "translator": "唐 地婆诃罗"},
                    {"label": "提云般若译（不思议佛境界分）", "cbeta": "T300",
                     "ids": ["T10n0300"], "translator": "唐 提云般若"},
                ],
            },
        ],
    },
    {
        "name": "法相宗",
        "key": "faxiang",
        "desc": "以唯识思想为核心",
        "groups": [
            {
                "name": "解深密经",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T676", "ids": ["T16n0676"],
                     "translator": "唐 玄奘"},
                ],
            },
            {
                "name": "瑜伽师地论",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T1579", "ids": ["T30n1579"],
                     "translator": "弥勒菩萨说·唐 玄奘译"},
                ],
            },
            {
                "name": "成唯识论",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T1585", "ids": ["T31n1585"],
                     "translator": "护法等菩萨造·唐 玄奘译"},
                ],
            },
        ],
    },
    {
        "name": "三论宗",
        "key": "sanlun",
        "desc": "以中观空义为核心",
        "groups": [
            {
                "name": "中论",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T1564", "ids": ["T30n1564"],
                     "translator": "龙树造·青目释·姚秦 鸠摩罗什译"},
                ],
            },
            {
                "name": "百论",
                "note": "本库仅存「百论序」与「百论卷下」，卷上缺失；正文以广百论本及其释论补足",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T1569", "ids": ["T30n1569"],
                     "translator": "提婆菩萨造·姚秦 鸠摩罗什译"},
                ],
            },
            {
                "name": "广百论本",
                "note": "补《百论》本论缺失部分",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T1570", "ids": ["T30n1570"],
                     "translator": "圣天菩萨造·唐 玄奘译"},
                ],
            },
            {
                "name": "大乘广百论释论",
                "note": "补《百论》释论缺失部分",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T1571", "ids": ["T30n1571"],
                     "translator": "圣天菩萨本·护法菩萨释·唐 玄奘译"},
                ],
            },
            {
                "name": "十二门论",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T1568", "ids": ["T30n1568"],
                     "translator": "龙树造·姚秦 鸠摩罗什译"},
                ],
            },
        ],
    },
    {
        "name": "律宗",
        "key": "lvzong",
        "desc": "以戒律为修行根本",
        "groups": [
            {
                "name": "四分律",
                "editions": [
                    {"label": "佛陀耶舍等译", "cbeta": "T1428", "ids": ["T22n1428"],
                     "translator": "姚秦 佛陀耶舍等"},
                ],
            },
            {
                "name": "四分律删繁补阙行事钞",
                "editions": [
                    {"label": "道宣撰", "cbeta": "T1804", "ids": ["T40n1804"],
                     "translator": "唐 道宣撰述"},
                ],
            },
        ],
    },
    {
        "name": "密宗",
        "key": "mizong",
        "desc": "以仪轨、真言、观想为主要修行",
        "groups": [
            {
                "name": "大日经",
                "note": "即《大毘卢遮那成佛神变加持经》，胎藏界根本经",
                "editions": [
                    {"label": "善无畏共一行译", "cbeta": "T848", "ids": ["T18n0848"],
                     "translator": "唐 善无畏共一行"},
                ],
            },
            {
                "name": "金刚顶经",
                "note": "二种卷本并收",
                "editions": [
                    {"label": "不空译（三卷本）", "cbeta": "T865", "ids": ["T18n0865"],
                     "translator": "唐 不空",
                     "base": "金刚顶一切如来真实摄大乘现证大教王经"},
                    {"label": "不空译（二卷本）", "cbeta": "T874", "ids": ["T18n0874"],
                     "translator": "唐 不空",
                     "base": "金刚顶一切如来真实摄大乘现证大教王经"},
                ],
            },
        ],
    },
]

# GATE_SPEC has the identical three-level shape as SECT_SPEC. A 法门 is a practice
# door rather than a school, so its folders lean on 品/章 (普门品, 耳根圆通章) and
# on 替代 texts where the corpus has no standalone file for the requested title.
GATE_SPEC = [
    {
        "name": "地藏法门",
        "key": "dizang",
        "desc": "超度亡灵，化解冤亲业障",
        "groups": [
            {
                "name": "地藏菩萨本愿经",
                "editions": [
                    {"label": "实叉难陀译", "cbeta": "T412", "ids": ["T13n0412"],
                     "translator": "唐 释实叉难陀"},
                ],
            },
            {
                "name": "占察善恶业报经",
                "note": "地藏法门自查因果业报的根本",
                "editions": [
                    {"label": "菩提灯译", "cbeta": "T839", "ids": ["T17n0839"],
                     "translator": "唐 菩提灯"},
                ],
            },
            {
                "name": "大乘大集地藏十轮经",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T411", "ids": ["T13n0411"],
                     "translator": "唐 玄奘"},
                ],
            },
        ],
    },
    {
        "name": "观音法门",
        "key": "guanyin",
        "desc": "消灾解厄，救难护身",
        "groups": [
            {
                "name": "观世音菩萨普门品",
                "note": "本库无独立分卷，普门品在《妙法莲华经》卷第七之内，"
                        "同卷另含妙音菩萨品、等观业受品",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T262", "files": ["T09n0262_007"],
                     "translator": "姚秦 鸠摩罗什"},
                ],
            },
            {
                "name": "般若波罗蜜多心经",
                "note": "二流通行本并收",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T250", "ids": ["T08n0250"],
                     "translator": "姚秦 鸠摩罗什"},
                    {"label": "玄奘译", "cbeta": "T251", "ids": ["T08n0251"],
                     "translator": "唐 玄奘"},
                ],
            },
            {
                "name": "千手千眼观世音菩萨大悲心陀罗尼",
                "editions": [
                    {"label": "不空译", "cbeta": "T1064", "ids": ["T20n1064"],
                     "translator": "唐 不空"},
                ],
            },
            {
                "name": "观世音菩萨耳根圆通章",
                "note": "本库无独立分卷，耳根圆通章在《楞严经》卷第六之内，"
                        "同卷另含观音所问圆通法门",
                "editions": [
                    {"label": "般剌蜜帝译", "cbeta": "T945",
                     "files": ["T19n0945_006"],
                     "translator": "唐 般剌蜜帝"},
                ],
            },
        ],
    },
    {
        "name": "药师法门",
        "key": "yaoshi",
        "desc": "祛病消灾，化解疾苦",
        "groups": [
            {
                "name": "药师琉璃光如来本愿功德经",
                "editions": [
                    {"label": "玄奘译", "cbeta": "T450", "ids": ["T14n0450"],
                     "translator": "唐 玄奘"},
                ],
            },
        ],
    },
    {
        "name": "弥勒法门",
        "key": "mile",
        "desc": "解忧释怀，欢喜知足",
        "groups": [
            {
                "name": "观弥勒菩萨上生兜率天经",
                "editions": [
                    {"label": "沮渠京声译", "cbeta": "T452", "ids": ["T14n0452"],
                     "translator": "宋 沮渠京声"},
                ],
            },
            {
                "name": "弥勒下生经",
                "editions": [
                    {"label": "竺法护译", "cbeta": "T453", "ids": ["T14n0453"],
                     "translator": "西晋 竺法护"},
                ],
            },
            {
                "name": "弥勒大成佛经",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T456", "ids": ["T14n0456"],
                     "translator": "姚秦 鸠摩罗什"},
                ],
            },
        ],
    },
    {
        "name": "净土法门",
        "key": "jingtu",
        "desc": "一心念佛，了脱生死",
        "groups": [
            {
                "name": "无量寿经",
                "editions": [
                    {"label": "康僧铠译", "cbeta": "T360", "ids": ["T12n0360"],
                     "translator": "曹魏 康僧铠"},
                ],
            },
            {
                "name": "观无量寿经",
                "editions": [
                    {"label": "康僧铠译", "cbeta": "T365", "ids": ["T12n0365"],
                     "translator": "曹魏 康僧铠"},
                ],
            },
            {
                "name": "阿弥陀经",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T366", "ids": ["T12n0366"],
                     "translator": "姚秦 鸠摩罗什"},
                ],
            },
            {
                "name": "华严经普贤行愿品",
                "note": "《华严经·普贤行愿品》全库缺失：八十卷本 T10n0279 全 80 卷"
                        "无此品正文（仅《入法界品》内 14 处引用），四十卷本 T10n0293 "
                        "虽每卷题「入不思议解脱境界普贤行愿品」亦不单独分卷。"
                        "此处代以八十卷本全经",
                "editions": [
                    {"label": "实叉难陀译（八十卷本全经）", "cbeta": "T279",
                     "ids": ["T10n0279"],
                     "translator": "唐 实叉难陀"},
                ],
            },
            {
                "name": "大势至菩萨念佛圆通章",
                "note": "本库无独立分卷，大势至念佛圆通章在《楞严经》卷第五之内，"
                        "同卷另含观音所问圆通法门",
                "editions": [
                    {"label": "般剌蜜帝译", "cbeta": "T945",
                     "files": ["T19n0945_005"],
                     "translator": "唐 般剌蜜帝"},
                ],
            },
            {
                "name": "往生论",
                "note": "世亲造·菩提流支译《往生论》全库缺失（T47n1977 在本库"
                        "是《净土疑辨》），改以唐·迦才撰《净土论》替代",
                "editions": [
                    {"label": "净土论（迦才撰）", "cbeta": "T1963", "ids": ["T47n1963"],
                     "translator": "唐 迦才撰"},
                ],
            },
        ],
    },
    {
        "name": "般若法门",
        "key": "bore",
        "desc": "看破放下，照见真相",
        "groups": [
            {
                "name": "金刚经",
                "note": "六译本并收，以鸠摩罗什本为通行本",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T235", "ids": ["T08n0235"],
                     "translator": "姚秦 鸠摩罗什"},
                    {"label": "菩提流支译", "cbeta": "T236a", "ids": ["T08n0236a"],
                     "translator": "元魏 菩提流支"},
                    {"label": "菩提留支译", "cbeta": "T236b", "ids": ["T08n0236b"],
                     "translator": "元魏 菩提留支"},
                    {"label": "真谛译", "cbeta": "T237", "ids": ["T08n0237"],
                     "translator": "陈 真谛"},
                    {"label": "笈多译", "cbeta": "T238", "ids": ["T08n0238"],
                     "translator": "隋 笈多"},
                    {"label": "义净译", "cbeta": "T239", "ids": ["T08n0239"],
                     "translator": "唐 义净"},
                ],
            },
            {
                "name": "般若波罗蜜多心经",
                "note": "二流通行本并收",
                "editions": [
                    {"label": "鸠摩罗什译", "cbeta": "T250", "ids": ["T08n0250"],
                     "translator": "姚秦 鸠摩罗什"},
                    {"label": "玄奘译", "cbeta": "T251", "ids": ["T08n0251"],
                     "translator": "唐 玄奘"},
                ],
            },
            {
                # 大般若波罗蜜多经 600 卷在本库分为十六会，每会各有会序，
                # 卷首题名只有「序」二字，15 个序文件重名。故卷次一律取 CBETA
                # 序号（已核对 584 个非序卷的卷号与序号完全一致），并按会切卷本。
                "name": "大般若波罗蜜多经",
                "note": "六百卷，十六会，各会含会序；卷次即 CBETA 序号",
                "editions": [
                    {"label": "初会（卷一–四百）", "cbeta": "T220",
                     "ids": ["T05n0220", "T06n0220"],
                     "volRange": [1, 400], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第二会（卷四〇一–四七八）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [401, 478], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第三会（卷四七九–五三七）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [479, 537], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第四会（卷五三八–五五五）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [538, 555], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第五会（卷五六–五六五）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [556, 565], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第六会（卷五六六–五七三）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [566, 573], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第七会 曼殊室利分（卷五七四–五七五）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [574, 575], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第八会 那伽室利分（卷五七六）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [576, 576], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第九会 能断金刚分（卷五七七）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [577, 577], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十会 般若理趣分（卷五七八）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [578, 578], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十一会 施波罗蜜多分（卷五七九–五八三）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [579, 583], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十二会 戒波罗蜜多分（卷五八四–五八八）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [584, 588], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十三会 忍波罗蜜多分（卷五八九）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [589, 589], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十四会 勤波罗蜜多分（卷五九〇）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [590, 590], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十五会 静虑波罗蜜多分（卷五九一–五九二）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [591, 592], "partFromVol": True,
                     "translator": "唐 玄奘"},
                    {"label": "第十六会 般若波罗蜜多分（卷五九三–六〇〇）", "cbeta": "T220",
                     "ids": ["T07n0220"],
                     "volRange": [593, 600], "partFromVol": True,
                     "translator": "唐 玄奘"},
                ],
            },
        ],
    },
    {
        "name": "楞严法门",
        "key": "lengyan",
        "desc": "降伏魔障，守护道心",
        "groups": [
            {
                "name": "大佛顶如来密因修证了义诸菩萨万行首楞严经",
                "note": "十卷全经，楞严咒见卷七、卷八；目录题名截断，此处补全",
                "editions": [
                    {"label": "般剌蜜帝译", "cbeta": "T945", "ids": ["T19n0945"],
                     "translator": "唐 般剌蜜帝",
                     "base": "大佛顶如来密因修证了义诸菩萨万行首楞严经"},
                ],
            },
        ],
    },
    {
        "name": "普贤行愿法门",
        "key": "puxian",
        "desc": "落实善行，利益众生",
        "groups": [
            {
                "name": "华严经普贤行愿品",
                "note": "《普贤行愿品》全库缺失（详见净土法门同条说明），"
                        "代以八十卷本全经；华严宗另收六译本全经，此处只列通行本",
                "editions": [
                    {"label": "实叉难陀译（八十卷本全经）", "cbeta": "T279",
                     "ids": ["T10n0279"],
                     "translator": "唐 实叉难陀"},
                ],
            },
        ],
    },
    {
        "name": "拜忏法门",
        "key": "baichan",
        "desc": "忏悔过愆，消业解冤",
        "groups": [
            {
                "name": "慈悲道场忏法",
                "note": "即梁武帝为郗皇后所集《梁皇宝忏》",
                "editions": [
                    {"label": "梁武帝集", "cbeta": "T1909", "ids": ["T45n1909"],
                     "translator": "梁 武帝集"},
                ],
            },
            {
                "name": "慈悲水忏法",
                "note": "即唐·悟达国师知玄所演《三昧水忏》",
                "editions": [
                    {"label": "悟达知玄演", "cbeta": "T1910", "ids": ["T45n1910"],
                     "translator": "唐 悟达知玄"},
                ],
            },
            {
                "name": "大悲经",
                "note": "《大悲忏》（千手千眼大悲心忏法）全库缺失，T45n1911 在本库"
                        "无此书；此处代以《佛说大悲经》五卷，非忏仪而是本经",
                "editions": [
                    {"label": "那连提耶舍译", "cbeta": "T380", "ids": ["T12n0380"],
                     "translator": "高齐 那连提耶舍"},
                ],
            },
            {
                "name": "佛说三十五佛名礼忏文",
                "note": "《八十八佛大忏悔文》非大藏经收录、全库缺失，"
                        "此处代以同性质的《佛说三十五佛名礼忏文》",
                "editions": [
                    {"label": "不空译", "cbeta": "T326", "ids": ["T12n0326"],
                     "translator": "唐 不空"},
                ],
            },
        ],
    },
    {
        "name": "施食法门",
        "key": "shishi",
        "desc": "救济饿鬼，冥阳两利",
        "groups": [
            {
                "name": "救拔焰口饿鬼陀罗尼经",
                "editions": [
                    {"label": "不空译", "cbeta": "T1313", "ids": ["T21n1313"],
                     "translator": "唐 不空"},
                ],
            },
        ],
    },
    {
        "name": "四念处法门",
        "key": "nianchu",
        "desc": "洞察身心，止息烦恼",
        "groups": [
            {
                "name": "妙法圣念处经",
                "note": "《大念处经》全库缺失（四念处经典今题《妙法圣念处经》），"
                        "此处即以此经八卷代之",
                "editions": [
                    {"label": "法天译", "cbeta": "T722", "ids": ["T17n0722"],
                     "translator": "宋 法天"},
                ],
            },
        ],
    },
    {
        "name": "头陀法门",
        "key": "toutuo",
        "desc": "简朴自持，克制物欲",
        "groups": [
            {
                "name": "十二头陀经",
                "editions": [
                    {"label": "求那跋陀罗译", "cbeta": "T783", "ids": ["T17n0783"],
                     "translator": "宋 求那跋陀罗"},
                ],
            },
        ],
    },
]


def load_catalog() -> list[dict]:
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def build_title_index(catalog: list[dict]) -> dict[str, dict]:
    """Catalog title (which embeds the ID) -> entry, keyed by ID."""
    out: dict[str, dict] = {}
    for entry in catalog:
        title = entry["t"]
        m = ID_RE.search(title)
        if not m:
            continue
        out[m.group(0)] = entry
    return out


def clean_line(line: str) -> str:
    """Drop CBETA editorial marks and collapse the full-width spacing used in
    imperial bylines ("奉　诏译" -> "奉诏译")."""
    s = CBETA_MARK_RE.sub("", line)
    s = s.replace("　", "").replace("\u3000", "")
    return re.sub(r"\s{2,}", " ", s).strip()


def read_head(path: Path, lines: int = 6) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return text.splitlines()[:lines]


HALF_SUFFIX_RE = re.compile(r"[（(](上|下)[）)]$")


def collapse_packed_halves(path: Path, part: str) -> str:
    """Some corpus files pack both halves of a volume into one file, so a label
    like "摩诃止观卷第一(上)" actually covers 上+下. When the same file also
    carries the opposite half header, drop the half marker.

    Only files whose label ends in (上)/(下) are read in full, so this costs
    almost nothing.
    """
    m = HALF_SUFFIX_RE.search(part)
    if not m:
        return part
    sibling = HALF_SUFFIX_RE.sub(
        "(下)" if m.group(1) == "上" else "(上)", part
    )
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return part
    return part[: m.start()] if sibling in text else part


def detect_part_name(head: list[str], base: str, *aliases: str) -> str:
    """Volume/part label carried at the head of a volume file, e.g. "卷第二",
    "卷上", "序", "目录", "品目", "一卷". Empty when the file has none (many
    continuation volumes simply repeat the sutra name).

    `aliases` are additional acceptable spellings of the sutra's own name, for
    the cases where the catalog title is truncated.
    """
    title = clean_line(head[0]) if head else ""
    names = {base, *aliases}
    for raw in head[1:4]:
        line = clean_line(raw)
        if not line or line.startswith("No.") or line == title or line in names:
            continue
        m = PART_RE.match(line)
        if m and clean_line(m.group("base")) in names:
            part = m.group("part")
            tail = EDITORIAL_TAIL_RE.sub("", m.group("rest") or "").strip()
            return PART_ORDINAL_RE.sub(r"\1", part + tail)
        m2 = TRAILING_PART_RE.search(line)
        if m2:
            return PART_ORDINAL_RE.sub(r"\1", m2.group("part"))
    return ""


def strip_title_volume(catalog_title: str) -> str:
    """Catalog title without the CBETA id suffix and without a trailing 卷第N,
    so the part label can be appended back without duplicating it."""
    t = ID_RE.sub("", catalog_title).strip()
    t = TITLE_VOL_RE.sub("", t).strip()
    return t or catalog_title


def collect_volumes(edition: dict, by_id: dict[str, dict]) -> tuple[list[dict], list[str]]:
    """Resolve one edition's CBETA ids into concrete volume records.

    The translator comes from the spec (authoritative) rather than scraped,
    because a volume file's head mixes in preface authors, imperial prefaces
    and CBETA editorial notes.
    """
    found: list[dict] = []
    missing: list[str] = []
    translator = edition.get("translator", "")
    base_override = edition.get("base", "")
    part_from_vol = edition.get("partFromVol", False)
    vol_range = edition.get("volRange")

    # `files` pins exact ids, for a 品/章 the corpus does not carry as its own
    # file; `ids` instead sweeps every catalog id carrying one CBETA prefix.
    if edition.get("files"):
        targets: list[str] = []
        for eid in edition["files"]:
            if eid in by_id:
                targets.append(eid)
            else:
                missing.append(eid)
    else:
        targets = []
        for prefix in edition["ids"]:
            hit = [eid for eid in by_id if eid.startswith(prefix)]
            hit.sort()
            if not hit:
                missing.append(prefix)
            targets.extend(hit)

    for eid in targets:
        entry = by_id[eid]
        vol = int(eid.rsplit("_", 1)[1])
        # A sutra split into several 卷本 (大般若的十六会) keeps only its share.
        if vol_range is not None and not (vol_range[0] <= vol <= vol_range[1]):
            continue
        src = ASCII_ROOT / eid[:3] / f"{eid}.txt"
        if not src.exists():
            missing.append(eid)
            continue
        if not translator:
            missing.append(f"{eid} (无译者标注)")
            continue
        derived = strip_title_volume(entry["t"])
        base = base_override or derived
        if re.search(r"卷[第上中下]", base[-2:]):
            raise SystemExit(
                f"{eid}: base 仍带卷标 {base!r}，会与 partName 重复"
            )
        if part_from_vol:
            # 会序 files all carry a bare "序", so the head label is unusable;
            # the CBETA ordinal is the only label that stays unique.
            part = "卷" + int_to_cn(vol)
        else:
            part = detect_part_name(
                read_head(src), derived, base if base_override else derived
            )
            part = collapse_packed_halves(src, part)
        found.append(
            {
                "title": entry["t"],
                "id": eid,
                "cbeta": f"{eid[:3]}n{eid.split('n')[1].split('_')[0]}",
                "assetPath": f"assets/sutras_ascii/{eid[:3]}/{eid}.txt",
                "translator": translator,
                "base": base,
                # Match the part title against both names: the catalog title
                # is often truncated, so only the override may match.
                "partName": part,
                "vol": vol,
                "words": entry.get("c", 0),
                "size": entry.get("s", ""),
            }
        )
    found.sort(key=lambda v: v["vol"])
    return found, missing


def build_menus(
    spec: list[dict], kind: str, by_id: dict[str, dict]
) -> tuple[list[dict], list[str]]:
    """Build one menu list (the 8 宗门 or the 12 法门) from its spec."""
    menus: list[dict] = []
    all_missing: list[str] = []

    for menu in spec:
        menu_key = f"{kind}:{menu['key']}"
        groups_out: list[dict] = []
        menu_words = 0
        menu_volumes = 0
        menu_editions = 0

        for group in menu["groups"]:
            editions_out: list[dict] = []
            group_words = 0
            group_volumes = 0
            # Scoped per group, not globally: the same sutra is legitimately
            # reachable from several menus (楞严经 from 观音/净土/楞严法门,
            # 金刚经 from 禅宗 and 般若法门) and from several 译本.
            seen_ids: set[str] = set()

            for ed in group["editions"]:
                volumes, missing = collect_volumes(ed, by_id)
                where = f"{menu['name']}/{group['name']}·{ed['label']}"
                all_missing.extend(f"{where}: {m}" for m in missing)
                for v in volumes:
                    if v["id"] in seen_ids:
                        raise SystemExit(
                            f"ERROR: {where} 重复收录 {v['id']}"
                        )
                    seen_ids.add(v["id"])

                if not volumes:
                    continue

                # Volume rows must be unique inside an edition, otherwise the
                # detail page shows indistinguishable rows.
                names = [v["base"] + v["partName"] for v in volumes]
                if len(set(names)) != len(names):
                    dupes = sorted({n for n in names if names.count(n) > 1})
                    raise SystemExit(f"ERROR: {where} 有重名卷 {dupes}")

                words = sum(v["words"] for v in volumes)
                group_words += words
                group_volumes += len(volumes)

                editions_out.append(
                    {
                        # "金刚经·鸠摩罗什译": the group is the folder, the label
                        # is the translator, so every edition is self-describing.
                        "name": f"{group['name']}·{ed['label']}",
                        "label": ed["label"],
                        "cbeta": ed.get("cbeta", ""),
                        "note": ed.get("note", ""),
                        "translator": ed.get("translator", ""),
                        "totalVolumes": len(volumes),
                        "totalWords": words,
                        "volumes": volumes,
                    }
                )

            if not editions_out:
                continue

            menu_editions += len(editions_out)
            menu_words += group_words
            menu_volumes += group_volumes
            groups_out.append(
                {
                    "key": f"{menu_key}#{group['name']}",
                    "name": group["name"],
                    "note": group.get("note", ""),
                    "totalEditions": len(editions_out),
                    "totalVolumes": group_volumes,
                    "totalWords": group_words,
                    "editions": editions_out,
                }
            )

        menus.append(
            {
                "key": menu_key,
                "name": menu["name"],
                "desc": menu["desc"],
                "totalGroups": len(groups_out),
                "totalEditions": menu_editions,
                "totalVolumes": menu_volumes,
                "totalWords": menu_words,
                "groups": groups_out,
            }
        )
    return menus, all_missing


def build() -> tuple[dict, list[str]]:
    catalog = load_catalog()
    by_id = build_title_index(catalog)

    sects, missing_sects = build_menus(SECT_SPEC, "menpai", by_id)
    gates, missing_gates = build_menus(GATE_SPEC, "famen", by_id)

    manifest = {
        "version": 3,
        "generatedAt": date.today().isoformat(),
        "totalSects": len(sects),
        "totalGates": len(gates),
        "totalGroups": sum(s["totalGroups"] for s in sects + gates),
        "totalEditions": sum(s["totalEditions"] for s in sects + gates),
        "totalVolumes": sum(s["totalVolumes"] for s in sects + gates),
        "totalWords": sum(s["totalWords"] for s in sects + gates),
        "sects": sects,
        "gates": gates,
    }
    return manifest, missing_sects + missing_gates


CN_DIGITS = "零一二三四五六七八九"
# CBETA 的「一卷」是排版残留，App 侧 SectSutraVolume._frontMatterLabels 同样抑制。
FRONT_MATTER_PARTS = {"目录", "品目", "一卷"}


def cn_to_int(text: str) -> int:
    """把「一」「十」「二十二」这类汉字数字转成整数，无法解析时返回 0。"""
    if not text or any(c not in CN_DIGITS + "十百" for c in text):
        return 0
    total = section = number = 0
    for c in text:
        if c == CN_DIGITS[0]:
            number = 0
        elif c == "十":
            section += (number or 1) * 10
            number = 0
        elif c == "百":
            section += (number or 1) * 100
            number = 0
        else:
            number = CN_DIGITS.index(c)
    return total + section + number


def int_to_cn(n: int) -> str:
    """sutraVolumeLabel 的 Python 镜像，保证 README 与 App 卷次体例一致。"""
    if n <= 0:
        return ""
    if n <= 10:
        return "十" if n == 10 else CN_DIGITS[n]
    if n < 20:
        return "十" + CN_DIGITS[n - 10]
    if n < 100:
        return f"{CN_DIGITS[n // 10]}十" + (CN_DIGITS[n % 10] if n % 10 else "")
    if n < 1000:
        head = f"{CN_DIGITS[n // 100]}百"
        rest = n % 100
        if rest == 0:
            return head
        if rest < 10:
            return head + "零" + CN_DIGITS[rest]
        return head + int_to_cn(rest)
    return str(n)


READ_MD_TITLE = "# 宗门与法门核心经典索引"
# 逐卷列表超过这个卷数就只记区间，否则大般若一家的 600 卷会把文档撑到无用。
README_VOLUME_TABLE_MAX = 50


def readme_display_name(volume: dict) -> str:
    """App 侧 SectSutraVolume.displayName 的镜像，用于 README 记录真实行标题。"""
    base, part = volume["base"], volume["partName"]
    if not part or part in FRONT_MATTER_PARTS:
        return base
    m = re.match(r"^卷第[一二三四五六七八九十百零]+", part)
    if m is None:
        return base + part
    n = cn_to_int(m.group(0).replace("第", ""))
    label = "" if n <= 0 else "卷" + int_to_cn(n)
    return f"{base}{label or m.group(0)}{part[m.end():]}"


def readme_row_title(edition: dict, volume: dict) -> str:
    """App 侧 SectSutraEdition.rowTitle 的镜像。"""
    if len(edition["volumes"]) == 1:
        return edition["name"]
    return readme_display_name(volume)


def render_readme(manifest: dict) -> str:
    lines: list[str] = []
    lines.append(READ_MD_TITLE)
    lines.append("")
    lines.append(
        "本目录是佛教八大宗门与十二法门的核心经典**索引**，由 "
        "`tools/build_sect_sutras.py` 从 `assets/sutras_ascii/`（8982 部经文）"
        "自动生成。"
    )
    lines.append("")
    lines.append("> **零复制**：本目录不含任何 `.txt` 正文。清单里只存经书 ID、"
                 "题名与规范资产路径 `assets/sutras_ascii/<卷>/<ID>.txt`，"
                 "App 读取时走既有 `SutraDownloader` / `ReadingPage` 链路。")
    lines.append("> 这样清单永远不会与 `assets/sutras_ascii/`（GitHub 下载源）或 "
                 "`assets/sutras_edited/`（管理员编辑版排版）脱节。")
    lines.append("")
    lines.append("重新生成：`python tools/build_sect_sutras.py`")
    lines.append("")
    lines.append("## 总览")
    lines.append("")
    lines.append("| 类别 | 宗门/法门 | 核心经典 | 译本 | 卷/文件 | 字数 |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: |")
    subtotals: list[tuple[str, int, int, int, int]] = []
    for category, field in (("宗门", "sects"), ("法门", "gates")):
        for s in manifest[field]:
            lines.append(
                f"| {category} | {s['name']} | {s['totalGroups']} | "
                f"{s['totalEditions']} | {s['totalVolumes']} | "
                f"{s['totalWords']:,} |"
            )
        subtotals.append(
            (
                category,
                sum(s["totalGroups"] for s in manifest[field]),
                sum(s["totalEditions"] for s in manifest[field]),
                sum(s["totalVolumes"] for s in manifest[field]),
                sum(s["totalWords"] for s in manifest[field]),
            )
        )
    for category, groups, eds, vols, words in subtotals:
        lines.append(
            f"| **{category}小计** | {len(manifest['sects' if category == '宗门' else 'gates'])} 个 "
            f"| **{groups}** | **{eds}** | **{vols}** | **{words:,}** |"
        )
    lines.append(
        f"| **合计** | **{manifest['totalSects']} 宗门 + {manifest['totalGates']} 法门** "
        f"| **{manifest['totalGroups']}** | **{manifest['totalEditions']}** | "
        f"**{manifest['totalVolumes']}** | **{manifest['totalWords']:,}** |"
    )
    lines.append("")

    for heading, field in (("八大宗门", "sects"), ("十二法门", "gates")):
        lines.append(f"## 明细：{heading}")
        lines.append("")
        for s in manifest[field]:
            lines.append(f"### {s['name']} — {s['desc']}")
            lines.append("")
            for g in s["groups"]:
                lines.append(f"#### {g['name']}")
                if g["note"]:
                    lines.append("")
                    lines.append(f"> {g['note']}")
                lines.append("")
                for ed in g["editions"]:
                    lines.append(f"##### {ed['name']}（{ed['cbeta']}）")
                    if ed["note"]:
                        lines.append("")
                        lines.append(f"> {ed['note']}")
                    lines.append("")
                    lines.extend(_readme_edition_rows(ed))
                    lines.append("")

    lines.append("## 已知数据缺口")
    lines.append("")
    for text in KNOWN_GAPS:
        lines.append(text)
        lines.append("")
    return "\n".join(lines)


def _readme_edition_rows(ed: dict) -> list[str]:
    """Per-volume table, or just a 卷次区间 when the edition is a whole 会/分."""
    volumes = ed["volumes"]
    lines: list[str] = []
    if len(volumes) > README_VOLUME_TABLE_MAX:
        lo, hi = volumes[0]["vol"], volumes[-1]["vol"]
        lines.append(
            f"共 {len(volumes)} 卷（{readme_display_name(volumes[0])} – "
            f"{readme_display_name(volumes[-1])}），逐卷清单见 `manifest.json`。"
        )
        lines.append("")
        return lines
    lines.append("| 卷 | 行标题 | 显示名 | 题名 | 译者/作者 | 字数 | assetPath |")
    lines.append("| ---: | --- | --- | --- | --- | ---: | --- |")
    for v in volumes:
        lines.append(
            f"| {v['vol']} | {readme_row_title(ed, v)} | "
            f"{readme_display_name(v)} | {v['title']} "
            f"| {v['translator']} | {v['words']:,} | `{v['assetPath']}` |"
        )
    lines.append("")
    return lines


KNOWN_GAPS = [
    "1. **《往生论》全库缺失**。世亲造·菩提流支译《往生论》在 CBETA 中编号 "
    "T47n1977，但本库该编号下是《净土疑辨》（另一书）。净土宗、净土法门"
    "「往生论」一栏改以唐·迦才撰《净土论》（T47n1963，九章三卷）替代，"
    "页面与清单均已标注。",
    "2. **《百论》卷上缺失**。T30n1569 在本库仅存「百论序」与「百论卷下」。"
    "三论宗「百论」一栏另收《广百论本》（T30n1570）与《大乘广百论释论》"
    "（T30n1571）以补本论与释论。",
    "3. **《华严经·普贤行愿品》全库缺失**。八十卷本 T10n0279 全 80 卷无此品"
    "正文（只在《入法界品》内出现 14 处引用）；四十卷本 T10n0293 每卷第 4 行"
    "「入不思议解脱境界普贤行愿品」是全经品题，正文仍分散在四十卷内，"
    "不单独分卷。净土法门与普贤行愿法门改以八十卷本全经（T10n0279）替代。",
    "4. **《大悲忏》全库缺失**。千手千眼大悲心忏法在 CBETA 中编号 T45n1911，"
    "本库无此编号。拜忏法门改以《佛说大悲经》（T12n0380，五卷）替代——"
    "它是本经而非忏仪，清单已注明。",
    "5. **《八十八佛大忏悔文》非大藏经收录**，本库自然没有。拜忏法门改以同性质"
    "的《佛说三十五佛名礼忏文》（T12n0326，唐·不空译）替代。",
    "6. **《大念处经》全库缺失**。四念处经典今题《妙法圣念处经》"
    "（T17n0722，宋·法天译，八卷），四念处法门即以此经代之。",
    "7. **品/章级条目没有独立分卷**。《观世音菩萨普门品》在《妙法莲华经》"
    "T09n0262_007（卷七）之内，《耳根圆通章》在 T19n0945_006（卷六）之内，"
    "《大势至念佛圆通章》在 T19n0945_005（卷五）之内。清单以 `files` 钉住"
    "这三个文件，点开是同卷全文，各条已注明所在卷与同卷其他品。",
    "8. **《大般若波罗蜜多经》按十六会切分**。600 卷分属十六会，"
    "每会各有会序，而会序文件题名一律只有「序」二字，15 个序文件重名。"
    "故卷次一律取 CBETA 序号（已核对 584 个非序卷的卷号与序号完全一致，"
    "且 1–600 连续无缺），并以「译本」层承载十六会，避免一张列表铺 600 行。",
]


def main() -> None:
    manifest, missing = build()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    OUT_MD.write_text(render_readme(manifest), encoding="utf-8")

    print(f"sects    : {manifest['totalSects']}")
    print(f"gates    : {manifest['totalGates']}")
    print(f"groups   : {manifest['totalGroups']}")
    print(f"editions : {manifest['totalEditions']}")
    print(f"volumes  : {manifest['totalVolumes']}")
    print(f"words    : {manifest['totalWords']:,}")
    print(f"json     : {OUT_JSON.relative_to(ROOT)} ({OUT_JSON.stat().st_size:,} bytes)")
    print(f"readme   : {OUT_MD.relative_to(ROOT)}")
    for category, field in (("宗门", "sects"), ("法门", "gates")):
        print(f"\n{category}:")
        for s in manifest[field]:
            print(
                f"  {s['name']:<7} {s['totalGroups']:>2} 部 "
                f"{s['totalEditions']:>2} 译本 {s['totalVolumes']:>3} 卷 "
                f"{s['totalWords']:>9,} 字"
            )
    if missing:
        print("\nMISSING:")
        for m in missing:
            print(f"  {m}")
        sys.exit(1)
    print("\nall resolved")


if __name__ == "__main__":
    main()
