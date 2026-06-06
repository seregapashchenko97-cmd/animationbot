import asyncio
import html
import logging
import os
import random
import re
import shutil
import subprocess
import tempfile
import urllib.parse
from pathlib import Path
from datetime import datetime, timezone, timedelta

import requests
import edge_tts
from aiogram import Bot, Dispatcher, F
from aiogram.filters import CommandStart
from aiogram.types import (
    FSInputFile,
    KeyboardButton,
    Message,
    ReplyKeyboardMarkup,
)
from gtts import gTTS
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BOT_TOKEN            = os.getenv("BOT_TOKEN", "")
VOICE                = os.getenv("VOICE", "en-US-BrianNeural")
TTS_PROVIDER         = os.getenv("TTS_PROVIDER", "edge").lower()
VOICE_SPEED          = float(os.getenv("VOICE_SPEED", "1.0"))
EDGE_RATE            = os.getenv("EDGE_RATE", "-5%")
EDGE_PITCH           = os.getenv("EDGE_PITCH", "-3Hz")
ALLOW_GTTS_FALLBACK  = os.getenv("ALLOW_GTTS_FALLBACK", "true").lower() == "true"
ELEVENLABS_API_KEY   = os.getenv("ELEVENLABS_API_KEY", "")
ELEVENLABS_VOICE_ID  = os.getenv("ELEVENLABS_VOICE_ID", "onwK4e9ZLuTAKqWW03F9")

YOUTUBE_CLIENT_ID      = os.getenv("YOUTUBE_CLIENT_ID", "")
YOUTUBE_CLIENT_SECRET  = os.getenv("YOUTUBE_CLIENT_SECRET", "")
YOUTUBE_REFRESH_TOKEN  = os.getenv("YOUTUBE_REFRESH_TOKEN", "")
YOUTUBE_PRIVACY_STATUS = os.getenv("YOUTUBE_PRIVACY_STATUS", "public")
YOUTUBE_CATEGORY_ID    = os.getenv("YOUTUBE_CATEGORY_ID", "22")

AUTOPILOT_ENABLED    = os.getenv("AUTOPILOT_ENABLED", "false").lower() == "true"
AUTOPILOT_USER_ID    = int(os.getenv("AUTOPILOT_USER_ID", "0"))
MAX_PARALLEL         = int(os.getenv("MAX_PARALLEL_GENERATIONS", "1"))

FPS = 30
W, H = 1920, 1080

AUTOPILOT_SCHEDULE_UTC = [14, 18, 22]
autopilot_fired: dict[str, set[int]] = {}

if not BOT_TOKEN:
    raise RuntimeError("BOT_TOKEN is missing")

bot = Bot(BOT_TOKEN, request_timeout=600)
dp  = Dispatcher()

active_users: set[int]          = set()
last_generated: dict[int, dict] = {}

BTN_START      = "🏠 Старт"
BTN_GENERATE   = "🎬 Генерировать видео"
BTN_REGENERATE = "🔄 Сгенерировать заново"
BTN_PUBLISH_YT = "📤 Опубликовать на YouTube"
BTN_RANDOM     = "🎲 Случайная тема"


def keyboard_main() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(keyboard=[
        [KeyboardButton(text=BTN_START)],
        [KeyboardButton(text=BTN_GENERATE)],
        [KeyboardButton(text=BTN_RANDOM)],
    ], resize_keyboard=True)


def keyboard_topics() -> ReplyKeyboardMarkup:
    rows = [[KeyboardButton(text=BTN_START)]]
    for t in TOPICS:
        rows.append([KeyboardButton(text=t["button"])])
    rows.append([KeyboardButton(text=BTN_RANDOM)])
    return ReplyKeyboardMarkup(keyboard=rows, resize_keyboard=True)


def keyboard_after() -> ReplyKeyboardMarkup:
    rows = [
        [KeyboardButton(text=BTN_START)],
        [KeyboardButton(text=BTN_REGENERATE)],
    ]
    if YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET and YOUTUBE_REFRESH_TOKEN:
        rows.append([KeyboardButton(text=BTN_PUBLISH_YT)])
    rows.append([KeyboardButton(text=BTN_GENERATE)])
    return ReplyKeyboardMarkup(keyboard=rows, resize_keyboard=True)


TOPICS = [
    {
        "button": "Salary Life $20K→$1M",
        "title": "Your Life at Every Salary Level — $20,000 to $1,000,000",
        "description": (
            "What does life actually look like at $20K, $50K, $100K, $500K, and $1 million a year?\n"
            "From struggling to pay rent to owning a private jet — here is the full picture.\n\n"
            "#salary #money #rich #poor #lifestyle #wealth #finance #personalfinance #income #millionaire"
        ),
        "hashtags": ["salary","money","rich","lifestyle","wealth","finance","millionaire","income","poor","personalfinance"],
        "style": "2D indie animation, flat shading, muted cinematic colors, detailed interior, soft lamp light, melancholic atmosphere, wide shot, no text, no watermark",
        "scenes": [
            {
                "image_prompt": "young man sitting in a tiny dark studio apartment, bills spread on table, single lamp, cracked walls, counting coins, worried expression",
                "narration": "At twenty thousand dollars a year, every single month is a calculation. Rent takes half your paycheck before you even open your fridge. You know exactly how many days until the next deposit. You eat the same five meals because anything else feels like a risk. This is not just being broke. This is the mental weight of never having a cushion."
            },
            {
                "image_prompt": "young man in modest but clean apartment, cooking pasta, small TV on counter, used furniture, quiet evening, content but tired face",
                "narration": "At fifty thousand dollars a year, something shifts. You stop checking your bank account before buying groceries. You can say yes to the occasional dinner out. The apartment is not fancy but it is yours. You start a savings account. You put twenty dollars in it. Then something breaks and the twenty dollars disappears. But you are no longer counting days."
            },
            {
                "image_prompt": "man in modern apartment, laptop open, online shopping screen, nice couch, city view from window, relaxed posture, evening light",
                "narration": "At one hundred thousand dollars a year you cross a psychological line most people never cross. You buy things without guilt. You have a plan. Maybe a car payment, a decent apartment, maybe even a small investment account you check on Sundays. The anxiety does not fully disappear but it becomes manageable. You start thinking about the future instead of just surviving the present."
            },
            {
                "image_prompt": "successful man in large modern home office, multiple monitors, suit jacket on chair, city skyline through floor-to-ceiling windows, coffee in hand, confident",
                "narration": "At five hundred thousand dollars a year you have crossed into a world most people only see in movies. Your problems are different now. You are thinking about tax strategy, about which accountant to hire, about whether to buy or lease. Your friends quietly change. Some drift away. Some ask for favors. You learn quickly who was there for you and who was there for the number."
            },
            {
                "image_prompt": "wealthy man alone in a massive penthouse living room, glass of wine, city lights below at night, elegant but empty space, contemplative mood",
                "narration": "At one million dollars a year the strangest thing happens. You realize money does not solve the problems you thought it would. It solves the ones at the bottom of the list. Rent, food, safety yes. Loneliness, purpose, the feeling that you matter no. The penthouse is quiet. The wine is expensive. And sometimes at midnight you scroll through your phone the same way you did back in that tiny apartment. Looking for something. Not sure what."
            },
            {
                "image_prompt": "man standing at floor-to-ceiling window looking at sunrise over city, silhouette, reflective pose, empty coffee mug, peaceful but complex expression",
                "narration": "The truth about money is that every level solves one set of problems and creates another. What changes most is not your life. It is what you are afraid of. At twenty thousand you fear losing everything. At a million you fear it meant nothing. The real question is not how much are you earning. The real question is what are you building it for."
            },
        ],
    },
    {
        "button": "Poor vs Rich Morning",
        "title": "Poor Person's Morning vs Rich Person's Morning — The Real Difference",
        "description": (
            "6 AM. Two people wake up. Same planet, completely different worlds.\n"
            "This is what a morning actually looks like at different income levels and why it matters more than you think.\n\n"
            "#morning #routine #rich #poor #mindset #money #productivity #lifestyle #wealth #success"
        ),
        "hashtags": ["morning","routine","rich","poor","mindset","money","productivity","lifestyle","wealth","success"],
        "style": "2D indie animation, flat shading, warm and cold color contrast, detailed interiors, cinematic framing, no text, no watermark",
        "scenes": [
            {
                "image_prompt": "dark bedroom, alarm clock showing 5:45 AM, man waking up with dark circles under eyes, cramped room, dirty laundry on floor, dread on face",
                "narration": "Five forty-five AM. The alarm goes off and the first thought is not what am I going to create today. It is how much time do I have before I have to leave. The commute is ninety minutes each way. Three hours of your life, every single day, sitting on a bus or a train going somewhere you did not choose."
            },
            {
                "image_prompt": "bright spacious bedroom, soft morning light, man waking up calmly, stretching, large windows with curtains, plants, organized minimalist room",
                "narration": "Six AM. On the other side of the city a different alarm goes off. But this person does not bolt upright. They lie still for a moment. They chose when to wake up. They chose where to live relative to where they work. Or they work from home. That choice just that one choice is worth tens of thousands of dollars a year in time alone."
            },
            {
                "image_prompt": "small cluttered kitchen, man making instant coffee and toast, checking phone for bill notifications, standing up eating, barely awake, morning rush",
                "narration": "Breakfast for the person at the bottom of the income ladder is functional. Something fast. Something cheap. Eaten standing up while checking if the electric bill went through. Food is fuel. There is no ritual. There is no pleasure. There is just getting through the morning so you can get through the day."
            },
            {
                "image_prompt": "large bright kitchen with island, person making smoothie and eggs, relaxed posture, reading news on tablet, sunlight pouring through window",
                "narration": "On the other side of the income gap, breakfast is an event. Not because the food is necessarily better but because there is time. Time is the real luxury. Not the smoothie. Not the eggs. The fact that you are not already calculating what you might miss if you slow down."
            },
            {
                "image_prompt": "man in crowded subway car, tired face, headphones in, pressed against other commuters, looking at phone, resigned exhausted expression",
                "narration": "The commute is where the gap becomes physical. Eighty minutes standing in a metal tube with strangers. Your body is there. Your mind is trying to be anywhere else. Research shows that a commute longer than forty-five minutes is one of the single strongest predictors of unhappiness stronger than many health conditions."
            },
            {
                "image_prompt": "man walking through quiet tree-lined street in morning, coffee in hand, calm, nearby home office visible, birds, natural light, peaceful",
                "narration": "The morning sets the tone for everything that follows. The biggest difference between a rich morning and a poor morning is not the coffee. It is agency. The ability to choose how the first two hours go. If you can design your morning you can design your day. And that compounds over years into something that looks like luck but is actually just time used differently."
            },
        ],
    },
    {
        "button": "No Money 30 Days",
        "title": "What Happens to Your Mind and Body After 30 Days With No Money",
        "description": (
            "Not a challenge. Not a YouTube experiment. The real psychological and physical effects of financial stress backed by research.\n"
            "What actually happens when the money runs out and stays out.\n\n"
            "#broke #nomoney #mentalhealth #stress #finance #poverty #psychology #health #money #survival"
        ),
        "hashtags": ["broke","nomoney","mentalhealth","stress","finance","poverty","psychology","health","money","survival"],
        "style": "2D indie animation, desaturated cold palette, detailed character expressions, documentary cinematic atmosphere, no text, no watermark",
        "scenes": [
            {
                "image_prompt": "man sitting on floor of empty apartment, back against wall, staring at nothing, dim daylight through window, phone face down beside him",
                "narration": "Day one without money feels manageable. You tell yourself it is temporary. You have been here before. But research from Princeton University found something disturbing. Financial scarcity does not just stress you. It actually consumes cognitive bandwidth. The mental load of being broke is equivalent to losing thirteen IQ points. You are not imagining that you cannot think straight. You literally cannot."
            },
            {
                "image_prompt": "man lying in bed mid-afternoon, curtains half closed, staring at ceiling, empty takeout box on floor nearby, time has stopped feeling real",
                "narration": "By the end of the first week, sleep changes. Not because you are lazy. Because cortisol the stress hormone spikes when your survival feels threatened. You stay awake running scenarios. What if this bill does not get paid. What if I cannot make rent. What if this is just how it is now. Your brain cannot tell the difference between a predator and a bank notice."
            },
            {
                "image_prompt": "man standing in kitchen looking at nearly empty fridge, drinking water instead of eating, calm but hollow expression, sparse countertops",
                "narration": "Food becomes a negotiation. You stop eating when you are hungry. You start eating based on what is cheapest and what stretches furthest. Ramen. Rice. Whatever is on sale. The irony is that poor nutrition accelerates the cognitive decline. The brain needs glucose, omega-3s, B vitamins. Financial stress causes you to eat the foods least equipped to help you think your way out of financial stress."
            },
            {
                "image_prompt": "man avoiding phone calls, sitting in dark room, several missed calls visible on phone screen glowing, isolation, withdrawn hunched posture",
                "narration": "Around week two something social happens. You start pulling away. Shame is evolutionary. It signals that you have fallen below the group threshold. So you stop answering calls. You decline the hangout because you cannot afford it and cannot explain why. And isolation studies consistently show accelerates depression faster than almost any other variable."
            },
            {
                "image_prompt": "man at public library computer filling out job applications, determined but exhausted expression, dark circles, fluorescent overhead lights",
                "narration": "Week three. The determination comes back in waves. You apply for jobs. You make plans. You reorganize everything mentally. This is the part no one talks about. The resilience that lives underneath the stress. The human brain is extraordinarily adaptive. It recalibrates its baseline, finds new angles, survives things that should not be survivable."
            },
            {
                "image_prompt": "man sitting on bench in park, sunlight on face, small paper coffee cup beside him, slight quiet smile, first moment of genuine peace in weeks",
                "narration": "After thirty days the person who comes out the other side is different. Not broken. Different. Sharper in some ways. More aware of what actually matters. Less tolerant of time being wasted. If there is one thing that extended financial hardship teaches it is that stability is not a given. And most people walking past you every day are one or two bad months away from sitting exactly where you sat."
            },
        ],
    },
    {
        "button": "Rich People Secrets",
        "title": "10 Things Rich People Do That They Never Talk About",
        "description": (
            "It is not about the cars or the houses. The real habits of wealthy people are quieter, stranger, and more uncomfortable than any motivational video will tell you.\n\n"
            "#rich #wealth #money #habits #success #millionaire #finance #secretsoftherich #mindset #investing"
        ),
        "hashtags": ["rich","wealth","money","habits","success","millionaire","finance","secretsoftherich","mindset","investing"],
        "style": "2D indie animation, elegant dark palette with warm gold accents, detailed wealthy interiors, mysterious cinematic atmosphere, no text, no watermark",
        "scenes": [
            {
                "image_prompt": "wealthy man alone in large personal library at night, reading by firelight, no phone visible, surrounded by tall bookshelves, complete stillness and contentment",
                "narration": "The first thing wealthy people do that they never post about is protect their attention like it is a physical asset. Because it is. The average CEO reads fifty-two books a year. Not business books. Books on history, psychology, biology. They are not trying to hack success. They are trying to understand how systems work. That is a different goal entirely."
            },
            {
                "image_prompt": "man in expensive suit sitting across from advisor at minimalist desk reviewing papers, serious focused conversation, floor-to-ceiling city view behind them",
                "narration": "Rich people pay other people to think about things they do not want to think about. Not because they are lazy. Because they understand opportunity cost. Every hour you spend filing your own taxes is an hour you are not spending on the thing that actually generates value. Delegation is not a luxury. At a certain level it becomes the job."
            },
            {
                "image_prompt": "wealthy man in plain casual clothes at weekend farmers market, buying vegetables, anonymous among crowd, simple canvas bag, genuinely relaxed",
                "narration": "Real wealth almost never looks like wealth. The flashy car, the logo bag that is new money performing wealth for an audience. Old money and self-made wealth at a serious level tends toward the understated. The houses are behind gates no one can see. The clothes are expensive but unbranded. The goal is to move through the world without being a target."
            },
            {
                "image_prompt": "man sitting alone at kitchen table very early morning, open journal, writing with pen, black coffee steam rising, complete silence, dark outside windows",
                "narration": "Structured reflection. Not diary writing. More like an after-action report on their own decisions. What worked. What did not. What they missed. What they would do differently. Warren Buffett famously spends eighty percent of his day reading and thinking. Most of us spend eighty percent of our day reacting."
            },
            {
                "image_prompt": "person confidently declining phone call at home office, relaxed but firm body language, calm face, bookshelves visible, clear and comfortable with saying no",
                "narration": "Rich people say no at a rate that would seem rude to most people. Not because they are arrogant. Because they have done the math on their time. Every yes is a no to something else. Most people say yes by default and no only when forced. High-net-worth individuals reverse this. The default is no. Yes requires justification."
            },
            {
                "image_prompt": "man drawing complex systems diagram on whiteboard alone in home office, arrows, feedback loops, deep in thought, sleeves rolled up, focused expression",
                "narration": "Wealthy people are obsessed with systems, not outcomes. They do not ask how do I make more money this month. They ask what is the mechanism that would make money without me having to be present. The goal is always to make the machine run without being the machine. That shift in thinking is the one that changes everything."
            },
        ],
    },
    {
        "button": "$1 a Day Food USA",
        "title": "Living on $1 a Day for Food in America — What You Actually Eat",
        "description": (
            "For 38 million Americans, this is not an experiment. This is Tuesday.\n"
            "Here is what one dollar a day for food actually looks like and what it does to you over time.\n\n"
            "#food #poverty #onedollar #budget #america #hunger #broke #finance #foodinsecurity #survival"
        ),
        "hashtags": ["food","poverty","onedollar","budget","america","hunger","broke","finance","foodinsecurity","survival"],
        "style": "2D indie animation, warm muted honest tones, detailed kitchen environments, unglamorous realism, documentary cinematic style, no text, no watermark",
        "scenes": [
            {
                "image_prompt": "simple meal on a cracked plate, rice and beans, glass of water, worn wooden kitchen table, single fork, soft natural window light",
                "narration": "One dollar a day. Thirty dollars a month. This is the food budget for tens of millions of Americans on SNAP benefits if they are lucky enough to qualify. At one dollar a day you are not choosing between healthy and unhealthy. You are choosing between eating and not eating. And the math forces a brutally narrow set of options."
            },
            {
                "image_prompt": "person at discount grocery store carefully reading price labels, holding dried beans and rice bags, calculator app open on phone, fluorescent store lighting",
                "narration": "The staples are always the same. Dried beans. Rice. Oats. Eggs when you can stretch to them. Bananas. Cabbage. The cheapest protein per gram. You become an involuntary nutrition economist. You know that pinto beans have more protein per dollar than almost any meat. You know that oats are cheaper per calorie than almost anything. You did not want to know these things. You had to."
            },
            {
                "image_prompt": "man stirring a large pot of vegetable soup in sparse kitchen, calm mechanical movement, one meal being stretched to last three days, minimal ingredients visible",
                "narration": "Batch cooking is not a lifestyle trend when you are at the dollar-a-day level. It is survival mathematics. You cook once and you eat the same thing for three days because the gas to cook again costs money too. Nothing gets thrown away. Ever. Wilted vegetables become soup. Day-old rice becomes fried rice with one egg."
            },
            {
                "image_prompt": "parent and young child sitting at small table eating a simple meal, warm but worn kitchen, tired parent giving child the bigger portion, quiet love in difficult circumstances",
                "narration": "When there are children involved the calculation changes completely. You eat less so they eat enough. You skip your own lunch without announcing it. You watch them finish their plate and call that dinner. This is happening in forty percent of American households with children in food-insecure situations. Not in other countries. Here."
            },
            {
                "image_prompt": "person in line at food bank, head slightly lowered, community center hallway, boxes of donated food on tables, quiet dignity and need in the same moment",
                "narration": "The food bank is not a last resort for most people who use it. It is a regular part of the budget strategy. The shame around it is entirely constructed. The people in that line are nurses, veterans, teachers, warehouse workers. They are not there because they made bad choices. They are there because the math does not work and they are doing what rational people do."
            },
            {
                "image_prompt": "man at apartment window at night, holding bowl of simple food, looking out at lit-up city, quiet reflection, not despair but a kind of calm reckoning",
                "narration": "Food insecurity does not just make you hungry. It makes you worse at your job, worse at parenting, worse at thinking clearly because your brain is spending forty percent of its bandwidth on the low-level alarm of not knowing when you will eat next. The one-dollar-a-day reality is not a story about food. It is a story about what it costs a country to let this be normal."
            },
        ],
    },
    {
        "button": "Middle Class Trap",
        "title": "The Middle Class Trap — Why Working Hard Keeps You Poor",
        "description": (
            "You followed the rules. College, job, car payment, mortgage.\n"
            "So why does it feel like you are running in place? Here is the trap no one warned you about.\n\n"
            "#middleclass #money #wealth #trap #finance #debt #ratrace #investing #freedom #personalfinance"
        ),
        "hashtags": ["middleclass","money","wealth","trap","finance","debt","ratrace","investing","freedom","personalfinance"],
        "style": "2D indie animation, suburban palette, detailed home and office environments, ironic tension between comfort and confinement, cinematic wide shots, no text, no watermark",
        "scenes": [
            {
                "image_prompt": "suburban house exterior at dawn, man in suit with briefcase walking to car in driveway, identical houses on both sides, grey morning sky, driving away",
                "narration": "You did everything right. You went to school. You got the job. You got the car and then the bigger car. The house. The kids. The lawn. From the outside it looks exactly like success is supposed to look. From the inside it feels like a treadmill someone else is setting the speed on."
            },
            {
                "image_prompt": "man at dining table surrounded by organized bills and statements, mortgage, car loan, student loan papers, tired face, cold coffee, careful calculations",
                "narration": "The trap is not poverty. Poverty is obvious. The trap is the illusion of financial stability that is actually leveraged debt. The average middle-class American has a mortgage, a car payment, student loans, and credit card debt. They look wealthy on paper. They are one missed paycheck from a crisis."
            },
            {
                "image_prompt": "man looking at two pieces of paper, one showing monthly budget written in detail, the other blank where an investment plan should be, living room setting",
                "narration": "The wealth gap between the middle class and the wealthy is not primarily an income gap. It is an asset gap. Middle class people trade time for money. Wealthy people build structures that generate money from capital. The middle class saves. The wealthy invest. Saving preserves money. Investing multiplies it."
            },
            {
                "image_prompt": "man getting a raise at work, celebrating briefly with coworkers, then immediately seeing a car dealership ad and a real estate listing for a bigger house, cycle of consumption",
                "narration": "Lifestyle inflation is the mechanism that keeps the trap locked. Every raise gets absorbed by a slightly nicer version of what you already had. The car gets upgraded. The apartment becomes a house. The vacations get slightly more expensive. The net result is that your savings rate stays approximately the same regardless of how much more you earn."
            },
            {
                "image_prompt": "man in his mid forties at kitchen table, looking at retirement calculator on laptop, face showing a quiet late realization, family photos visible on wall behind him",
                "narration": "The moment most middle-class people realize the trap is usually in their forties. They have been working for twenty years. They look at their retirement account. They do the math. They realize that if they stopped working tomorrow they would run out of money in less than five years. After twenty years of doing everything right."
            },
            {
                "image_prompt": "couple sitting at kitchen table together, cups of tea, talking calmly and seriously, papers and laptop open, making a new plan together, early morning first light",
                "narration": "The way out is not dramatic. It is not a side hustle or a cryptocurrency. It is boring and it is slow and it works. Stop trading all your time for money and start having some of your money work while you sleep. Index funds, real estate, anything that compounds. The trap is not permanent. But you have to see it clearly before you can walk out of it."
            },
        ],
    },
]

BUTTON_TO_TOPIC = {t["button"]: t for t in TOPICS}


def get_session() -> requests.Session:
    s = requests.Session()
    retry = Retry(total=4, backoff_factor=2, status_forcelist=[429, 500, 502, 503, 504])
    adapter = HTTPAdapter(max_retries=retry)
    s.mount("http://", adapter); s.mount("https://", adapter)
    return s


def clean_filename(text: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "_", text).strip("_")[:50] or "video"


def clean_text(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


# ── Image generation ──────────────────────────────────────────────────────────

def generate_image(prompt: str, style: str, index: int, out_dir: Path) -> Path:
    full_prompt = f"{prompt}, {style}"
    encoded = urllib.parse.quote(full_prompt)
    seed = random.randint(1, 999999)
    url = f"https://image.pollinations.ai/prompt/{encoded}?width={W}&height={H}&nologo=true&seed={seed}"
    out_path = out_dir / f"frame_{index:03d}.jpg"
    session = get_session()
    for attempt in range(4):
        try:
            r = session.get(url, timeout=120)
            r.raise_for_status()
            out_path.write_bytes(r.content)
            logger.info("Image %d OK (%d bytes)", index, len(r.content))
            return out_path
        except Exception as e:
            import time
            wait = 5 * (attempt + 1)
            logger.warning("Image %d attempt %d: %s — retry %ds", index, attempt+1, e, wait)
            time.sleep(wait)
    raise RuntimeError(f"Image {index} failed after 4 attempts")


def generate_all_images(topic: dict, out_dir: Path) -> list[Path]:
    return [generate_image(s["image_prompt"], topic["style"], i, out_dir)
            for i, s in enumerate(topic["scenes"])]


# ── TTS ───────────────────────────────────────────────────────────────────────

async def make_voiceover(text: str, out_path: Path) -> None:
    raw = out_path.with_name(f"{out_path.stem}_raw.mp3")
    if TTS_PROVIDER == "gtts":
        await asyncio.to_thread(_gtts, text, raw)
    elif TTS_PROVIDER == "elevenlabs":
        await asyncio.to_thread(_elevenlabs, text, raw)
    else:
        await _edge(text, raw)
    _speed_audio(raw, out_path, VOICE_SPEED)


async def _edge(text: str, out_path: Path) -> None:
    voice = VOICE.strip().rstrip(".")
    last_err = None
    for attempt in range(3):
        try:
            c = edge_tts.Communicate(text, voice, rate=EDGE_RATE, pitch=EDGE_PITCH)
            await c.save(str(out_path)); return
        except Exception as e:
            last_err = e; await asyncio.sleep(2 ** attempt)
    if ALLOW_GTTS_FALLBACK:
        await asyncio.to_thread(_gtts, text, out_path)
    else:
        raise last_err


def _gtts(text: str, out_path: Path) -> None:
    gTTS(text=text, lang="en", tld="com", slow=False).save(str(out_path))


def _elevenlabs(text: str, out_path: Path) -> None:
    if not ELEVENLABS_API_KEY: raise RuntimeError("ELEVENLABS_API_KEY missing")
    r = get_session().post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVENLABS_VOICE_ID}",
        headers={"xi-api-key": ELEVENLABS_API_KEY, "Content-Type": "application/json", "Accept": "audio/mpeg"},
        json={"text": text, "model_id": "eleven_multilingual_v2",
              "voice_settings": {"stability": 0.34, "similarity_boost": 0.82, "style": 0.45, "use_speaker_boost": True}},
        timeout=120)
    r.raise_for_status(); out_path.write_bytes(r.content)


def _speed_audio(src: Path, dst: Path, speed: float) -> None:
    if abs(speed - 1.0) < 0.01:
        shutil.copyfile(src, dst); return
    filters, r = [], speed
    while r > 2.0: filters.append("atempo=2.0"); r /= 2.0
    while r < 0.5: filters.append("atempo=0.5"); r /= 0.5
    filters.append(f"atempo={r:.4f}")
    subprocess.run(["ffmpeg", "-y", "-i", str(src), "-filter:a", ",".join(filters), "-vn", str(dst)],
                   check=True, capture_output=True)


def ffprobe_duration(path: Path) -> float:
    p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
                       check=True, capture_output=True, text=True)
    return float(p.stdout.strip())


# ── Subtitles ─────────────────────────────────────────────────────────────────

def _ass_time(s: float) -> str:
    s = max(0.0, s)
    h, m, sec, cs = int(s//3600), int((s%3600)//60), int(s%60), int((s-int(s))*100)
    return f"{h}:{m:02d}:{sec:02d}.{cs:02d}"


def write_subtitles(scenes: list[dict], durations: list[float], out_path: Path) -> None:
    header = (
        f"[Script Info]\nScriptType: v4.00+\nPlayResX: {W}\nPlayResY: {H}\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Georgia,68,&H00FFFFFF,&H000000FF,&H00000000,&HAA000000,"
        "1,0,0,0,100,100,1.2,0,1,5,3,2,80,80,60,1\n\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    )
    lines = [header]
    cursor = 0.0
    for scene, dur in zip(scenes, durations):
        words = clean_text(scene["narration"]).split()
        chunks = [" ".join(words[i:i+6]) for i in range(0, len(words), 6)]
        if not chunks:
            cursor += dur; continue
        chunk_dur = dur / len(chunks)
        for chunk in chunks:
            t = clean_text(chunk).replace("\\","").replace("{","(").replace("}",")")
            lines.append(f"Dialogue: 0,{_ass_time(cursor)},{_ass_time(cursor+chunk_dur-0.05)},Default,,0,0,0,,{t}\n")
            cursor += chunk_dur
    out_path.write_text("".join(lines), encoding="utf-8")


# ── Video assembly ────────────────────────────────────────────────────────────

def image_to_clip(img_path: Path, duration: float, out_path: Path) -> None:
    d = int(duration * FPS)
    vf = (
        f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},"
        f"zoompan=z='min(zoom+0.0003,1.04)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
        f":d={d}:s={W}x{H}:fps={FPS},setsar=1"
    )
    subprocess.run(
        ["ffmpeg", "-y", "-loop", "1", "-i", str(img_path),
         "-t", f"{duration:.3f}", "-vf", vf,
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-an", str(out_path)],
        check=True, capture_output=True)


def concat_files(paths: list[Path], tmp_dir: Path, out_name: str, copy: bool = True) -> Path:
    lf = tmp_dir / f"list_{out_name}.txt"
    lf.write_text("".join(f"file '{p.as_posix()}'\n" for p in paths))
    out = tmp_dir / out_name
    cmd = ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lf)]
    if copy: cmd += ["-c", "copy"]
    cmd.append(str(out))
    subprocess.run(cmd, check=True, capture_output=True)
    return out


def burn_subs_and_audio(base_video: Path, audio: Path, subs: Path, out: Path) -> None:
    sub_path = subs.as_posix().replace(":", r"\:").replace("'", r"\'")
    dur = ffprobe_duration(audio)
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(base_video), "-i", str(audio),
         "-t", f"{dur:.3f}", "-vf", f"subtitles='{sub_path}'",
         "-map", "0:v", "-map", "1:a",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
         "-maxrate", "4M", "-bufsize", "8M",
         "-c:a", "aac", "-b:a", "192k", "-shortest", str(out)],
        check=True, capture_output=True)


async def generate_full_video(topic: dict) -> tuple[Path, float]:
    tmp = Path(tempfile.mkdtemp(prefix="longbot_"))
    scenes = topic["scenes"]

    logger.info("Generating %d images...", len(scenes))
    image_paths = await asyncio.to_thread(generate_all_images, topic, tmp)

    logger.info("Generating voiceovers...")
    audio_paths: list[Path] = []
    for i, scene in enumerate(scenes):
        text = ". ".join(clean_text(scene["narration"]).rstrip(".!?").split(". ")) + "."
        ap = tmp / f"audio_{i:03d}.mp3"
        await make_voiceover(text, ap)
        audio_paths.append(ap)

    audio_durations = [ffprobe_duration(p) for p in audio_paths]

    logger.info("Building video clips...")
    clip_paths: list[Path] = []
    for i, (img, dur) in enumerate(zip(image_paths, audio_durations)):
        cp = tmp / f"clip_{i:03d}.mp4"
        await asyncio.to_thread(image_to_clip, img, dur + 0.5, cp)
        clip_paths.append(cp)

    base_video = await asyncio.to_thread(concat_files, clip_paths, tmp, "base_video.mp4")
    full_audio = await asyncio.to_thread(concat_files, audio_paths, tmp, "full_audio.mp3")

    subs = tmp / "subs.ass"
    write_subtitles(scenes, audio_durations, subs)

    out_path = tmp / f"{clean_filename(topic['title'])}.mp4"
    await asyncio.to_thread(burn_subs_and_audio, base_video, full_audio, subs, out_path)

    total = sum(audio_durations)
    logger.info("Done: %.0f seconds", total)
    return out_path, total


# ── YouTube ───────────────────────────────────────────────────────────────────

def upload_to_youtube(video_path: Path, topic: dict) -> str:
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload

    creds = Credentials(token=None, refresh_token=YOUTUBE_REFRESH_TOKEN,
                        token_uri="https://oauth2.googleapis.com/token",
                        client_id=YOUTUBE_CLIENT_ID, client_secret=YOUTUBE_CLIENT_SECRET,
                        scopes=["https://www.googleapis.com/auth/youtube.upload"])
    creds.refresh(Request())
    yt = build("youtube", "v3", credentials=creds)
    media = MediaFileUpload(str(video_path), chunksize=-1, resumable=True, mimetype="video/mp4")
    req = yt.videos().insert(
        part="snippet,status",
        body={"snippet": {"title": topic["title"], "description": topic["description"],
                          "tags": topic["hashtags"], "categoryId": YOUTUBE_CATEGORY_ID},
              "status": {"privacyStatus": YOUTUBE_PRIVACY_STATUS, "selfDeclaredMadeForKids": False}},
        media_body=media)
    resp = None
    while resp is None: _, resp = req.next_chunk()
    url = f"https://www.youtube.com/watch?v={resp['id']}"
    logger.info("YouTube: %s", url)
    return url


# ── Bot ───────────────────────────────────────────────────────────────────────

async def start_generation(message: Message, topic: dict) -> None:
    uid = message.from_user.id
    if uid in active_users:
        await message.answer("Видео уже генерируется. Подожди."); return
    if len(active_users) >= MAX_PARALLEL:
        await message.answer("Сейчас идёт генерация. Попробуй позже."); return
    active_users.add(uid)
    last_generated[uid] = {"last_topic": topic}
    n = len(topic["scenes"])
    await message.answer(
        f"⏳ <b>Генерирую видео:</b>\n{topic['title']}\n\n"
        f"📸 Сцен: {n} изображений + озвучка\n"
        f"⏱ Примерно {n*1}–{n*2} минут...",
        parse_mode="HTML", reply_markup=keyboard_main())
    asyncio.create_task(_run(message, topic))


async def _run(message: Message, topic: dict) -> None:
    uid = message.from_user.id
    try:
        video_path, duration = await generate_full_video(topic)
        last_generated[uid] = {"path": video_path, "topic": topic, "last_topic": topic}
        mins, secs = int(duration // 60), int(duration % 60)
        caption = (
            f"✅ <b>{topic['title']}</b>\n\n"
            f"⏱ {mins}:{secs:02d}\n\n"
            f"<b>YouTube описание:</b>\n{topic['description'][:800]}"
        )
        size_mb = video_path.stat().st_size / 1024 / 1024
        if size_mb > 49:
            await message.answer(
                f"⚠️ Видео {size_mb:.0f}MB — большое для Telegram.\nНажми кнопку ниже чтобы опубликовать на YouTube.",
                parse_mode="HTML", reply_markup=keyboard_after())
        else:
            await message.answer_video(
                FSInputFile(video_path, filename="video.mp4"),
                caption=caption, parse_mode="HTML",
                supports_streaming=True, request_timeout=600)
            await message.answer("Выбери действие 👇", reply_markup=keyboard_after())
    except Exception as e:
        logger.error("Generation error: %s", e, exc_info=True)
        await message.answer(f"❌ Ошибка:\n{e}", reply_markup=keyboard_main())
    finally:
        active_users.discard(uid)


# ── Autopilot ─────────────────────────────────────────────────────────────────

_ap_recent: list[str] = []

def _ap_topic() -> dict:
    global _ap_recent
    c = [t for t in TOPICS if t["button"] not in _ap_recent]
    if not c: _ap_recent = []; c = TOPICS.copy()
    t = random.choice(c)
    _ap_recent.append(t["button"]); _ap_recent = _ap_recent[-3:]
    return t


def _next_slot() -> tuple[int, int]:
    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    fired = autopilot_fired.get(today, set())
    for h in sorted(AUTOPILOT_SCHEDULE_UTC):
        if h not in fired:
            t = now.replace(hour=h, minute=random.randint(0, 14), second=0, microsecond=0)
            if t > now: return int((t - now).total_seconds()), h
    tom = (now + timedelta(days=1)).replace(
        hour=AUTOPILOT_SCHEDULE_UTC[0], minute=random.randint(0, 14), second=0, microsecond=0)
    return int((tom - now).total_seconds()), AUTOPILOT_SCHEDULE_UTC[0]


async def autopilot_loop() -> None:
    if not AUTOPILOT_ENABLED: return
    if not (YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET and YOUTUBE_REFRESH_TOKEN):
        logger.warning("Autopilot: YouTube creds missing"); return
    logger.info("Autopilot ready. UTC slots: %s", AUTOPILOT_SCHEDULE_UTC)
    while True:
        wait, hour = _next_slot()
        h, rem = divmod(wait, 3600)
        if AUTOPILOT_USER_ID:
            await bot.send_message(AUTOPILOT_USER_ID,
                f"🕐 Автопилот: публикация через {h}ч {rem//60}мин (UTC {hour:02d}:xx)")
        await asyncio.sleep(wait)
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        autopilot_fired.setdefault(today, set()).add(hour)
        topic = _ap_topic()
        try:
            if AUTOPILOT_USER_ID:
                await bot.send_message(AUTOPILOT_USER_ID,
                    f"🤖 Генерирую:\n<b>{topic['title']}</b>", parse_mode="HTML")
            video_path, dur = await generate_full_video(topic)
            url = await asyncio.to_thread(upload_to_youtube, video_path, topic)
            if AUTOPILOT_USER_ID:
                await bot.send_message(AUTOPILOT_USER_ID,
                    f"✅ Опубликовано:\n<b>{topic['title']}</b>\n🔗 {url}\n⏱ {int(dur//60)} мин",
                    parse_mode="HTML")
        except Exception as e:
            logger.error("Autopilot: %s", e, exc_info=True)
            if AUTOPILOT_USER_ID:
                await bot.send_message(AUTOPILOT_USER_ID, f"❌ Автопилот ошибка: {e}")
        await asyncio.sleep(60)


# ── Handlers ──────────────────────────────────────────────────────────────────

@dp.message(CommandStart())
async def cmd_start(message: Message) -> None:
    topics_list = "\n".join(f"• {t['title']}" for t in TOPICS)
    await message.answer(
        "👋 <b>YouTube Long Video Bot</b>\n\n"
        "📸 AI-фото (Pollinations) • 🎙 Озвучка • 📝 Субтитры • 🎬 5+ минут\n\n"
        f"<b>Темы:</b>\n{topics_list}\n\n"
        "Нажми <b>Генерировать видео</b> 👇",
        parse_mode="HTML", reply_markup=keyboard_main())


@dp.message(F.text == BTN_START)
async def h_start(message: Message) -> None:
    await message.answer("Главное меню 👇", reply_markup=keyboard_main())


@dp.message(F.text == BTN_GENERATE)
async def h_generate(message: Message) -> None:
    await message.answer("🎬 Выбери тему 👇", reply_markup=keyboard_topics())


@dp.message(F.text == BTN_RANDOM)
async def h_random(message: Message) -> None:
    await start_generation(message, random.choice(TOPICS))


@dp.message(F.text == BTN_REGENERATE)
async def h_regen(message: Message) -> None:
    uid = message.from_user.id
    data = last_generated.get(uid)
    topic = data.get("last_topic", random.choice(TOPICS)) if data else random.choice(TOPICS)
    await start_generation(message, topic)


@dp.message(F.text == BTN_PUBLISH_YT)
async def h_publish(message: Message) -> None:
    uid = message.from_user.id
    data = last_generated.get(uid)
    if not data or "path" not in data:
        await message.answer("Нет готового видео. Сначала сгенерируй."); return
    if not (YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET and YOUTUBE_REFRESH_TOKEN):
        await message.answer("YouTube не настроен.\nНужны: YOUTUBE_CLIENT_ID, YOUTUBE_CLIENT_SECRET, YOUTUBE_REFRESH_TOKEN"); return
    await message.answer("⏳ Публикую на YouTube...", reply_markup=keyboard_main())
    try:
        url = await asyncio.to_thread(upload_to_youtube, data["path"], data["topic"])
        await message.answer(f"✅ <b>Опубликовано!</b>\n\n🔗 {url}\n\n<b>{data['topic']['title']}</b>",
                             parse_mode="HTML", reply_markup=keyboard_main())
    except Exception as e:
        logger.error("Publish: %s", e, exc_info=True)
        await message.answer(f"❌ Ошибка: {e}", reply_markup=keyboard_main())


@dp.message(F.text.in_(set(BUTTON_TO_TOPIC.keys())))
async def h_topic(message: Message) -> None:
    await start_generation(message, BUTTON_TO_TOPIC[message.text])


@dp.message()
async def fallback(message: Message) -> None:
    await message.answer("Нажми кнопку 👇", reply_markup=keyboard_main())


# ── Entry ─────────────────────────────────────────────────────────────────────

async def main() -> None:
    for t in ("ffmpeg", "ffprobe"):
        if shutil.which(t) is None: raise RuntimeError(f"{t} not found")
    await bot.delete_webhook(drop_pending_updates=True)
    if AUTOPILOT_ENABLED:
        asyncio.create_task(autopilot_loop())
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
