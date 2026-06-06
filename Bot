import asyncio
import logging
import os
import random
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes
from video_generator import VideoGenerator
from topic_generator import TopicGenerator
from apscheduler.schedulers.asyncio import AsyncIOScheduler

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

BOT_TOKEN = os.getenv("BOT_TOKEN")
OWNER_ID = int(os.getenv("OWNER_ID", "0"))

video_gen = VideoGenerator()
topic_gen = TopicGenerator()
scheduler = AsyncIOScheduler()


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    keyboard = [
        [InlineKeyboardButton("🎬 Generate Video", callback_data="generate_video")],
        [InlineKeyboardButton("📋 Topics List", callback_data="topics_list")],
        [InlineKeyboardButton("ℹ️ Status", callback_data="status")],
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        "🤖 *Dark Story Video Bot*\n\n"
        "I create cinematic animated-style videos about money, poverty, and psychology "
        "for YouTube — automatically.\n\n"
        "📅 *Auto-post:* Every day at 10:00 AM\n"
        "🎨 *Style:* Dark animated illustrations\n"
        "⏱ *Duration:* ~10 minutes\n\n"
        "Choose an action:",
        parse_mode="Markdown",
        reply_markup=reply_markup
    )


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    if query.data == "generate_video":
        await generate_video_handler(query, context)
    elif query.data == "topics_list":
        await show_topics(query, context)
    elif query.data == "status":
        await show_status(query, context)
    elif query.data == "back_to_menu":
        await back_to_menu(query, context)


async def generate_video_handler(query, context):
    await query.edit_message_text(
        "⏳ *Starting video generation...*\n\n"
        "📝 Generating topic and script...\n"
        "This will take 15-25 minutes. I'll send you the video when it's ready.",
        parse_mode="Markdown"
    )

    asyncio.create_task(generate_and_send(context.bot, query.from_user.id))


async def generate_and_send(bot, user_id):
    try:
        await bot.send_message(
            chat_id=user_id,
            text="🎯 *Step 1/4:* Generating topic and script...",
            parse_mode="Markdown"
        )

        topic_data = topic_gen.generate_topic()

        await bot.send_message(
            chat_id=user_id,
            text=f"✅ *Topic selected:*\n\n"
                 f"🇺🇸 EN: `{topic_data['title_en']}`\n"
                 f"🇷🇺 RU: `{topic_data['title_ru']}`\n\n"
                 f"🎨 *Step 2/4:* Generating {len(topic_data['scenes'])} scene images...\n"
                 f"_(this takes ~10 minutes)_",
            parse_mode="Markdown"
        )

        video_path, script_text = await video_gen.create_video(topic_data, bot, user_id)

        await bot.send_message(
            chat_id=user_id,
            text="✅ *Step 4/4:* Video ready! Sending for review...",
            parse_mode="Markdown"
        )

        review_text = (
            f"🎬 *VIDEO READY FOR REVIEW*\n\n"
            f"📌 *Тема (RU):* {topic_data['title_ru']}\n"
            f"📌 *Title (EN):* {topic_data['title_en']}\n\n"
            f"📝 *Описание для YouTube (RU):*\n{topic_data['description_ru']}\n\n"
            f"🏷 *Tags:* {topic_data['tags']}\n\n"
            f"⏱ Длительность: ~10 мин | Кадров: {len(topic_data['scenes'])}\n\n"
            f"✅ Одобрить для публикации?"
        )

        with open(video_path, 'rb') as video_file:
            await bot.send_video(
                chat_id=user_id,
                video=video_file,
                caption=review_text,
                parse_mode="Markdown",
                supports_streaming=True
            )

        os.remove(video_path)

    except Exception as e:
        logger.error(f"Video generation error: {e}", exc_info=True)
        await bot.send_message(
            chat_id=user_id,
            text=f"❌ *Error during generation:*\n`{str(e)}`\n\nTry again or check logs.",
            parse_mode="Markdown"
        )


async def show_topics(query, context):
    topics = topic_gen.get_sample_topics()
    text = "📋 *Sample Topics (auto-generated each time):*\n\n"
    for i, t in enumerate(topics[:8], 1):
        text += f"{i}. {t['title_en']}\n"
    text += "\n_Each video gets a unique new topic_"

    keyboard = [[InlineKeyboardButton("◀️ Back", callback_data="back_to_menu")]]
    await query.edit_message_text(text, parse_mode="Markdown",
                                   reply_markup=InlineKeyboardMarkup(keyboard))


async def show_status(query, context):
    next_job = scheduler.get_jobs()
    next_run = next_job[0].next_run_time if next_job else "Not scheduled"

    text = (
        f"📊 *Bot Status*\n\n"
        f"✅ Bot: Online\n"
        f"🕐 Next auto-generation: `{next_run}`\n"
        f"🎨 Image engine: Pollinations.ai (free)\n"
        f"🔊 Voice engine: Edge-TTS (free)\n"
        f"🎬 Video engine: FFmpeg\n"
        f"📺 Style: Dark animated illustration\n"
    )
    keyboard = [[InlineKeyboardButton("◀️ Back", callback_data="back_to_menu")]]
    await query.edit_message_text(text, parse_mode="Markdown",
                                   reply_markup=InlineKeyboardMarkup(keyboard))


async def back_to_menu(query, context):
    keyboard = [
        [InlineKeyboardButton("🎬 Generate Video", callback_data="generate_video")],
        [InlineKeyboardButton("📋 Topics List", callback_data="topics_list")],
        [InlineKeyboardButton("ℹ️ Status", callback_data="status")],
    ]
    await query.edit_message_text(
        "🤖 *Dark Story Video Bot*\n\nChoose an action:",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(keyboard)
    )


async def auto_generate(bot):
    logger.info("Starting scheduled auto-generation...")
    await generate_and_send(bot, OWNER_ID)


def main():
    app = Application.builder().token(BOT_TOKEN).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(button_handler))

    scheduler.add_job(
        auto_generate,
        'cron',
        hour=10,
        minute=0,
        args=[app.bot]
    )
    scheduler.start()

    logger.info("Bot started!")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
