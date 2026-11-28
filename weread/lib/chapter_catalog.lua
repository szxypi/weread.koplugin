-- Common chapter catalog bounds and field names for reading and source checks.
return {
    MAX_CHAPTERS = 20000,
    MAX_PACKAGE_BYTES = 32 * 1024 * 1024,
    UID_FIELDS = { "chapterUid", "chapterId", "chapter_uid" },
    INDEX_FIELDS = { "chapterIdx", "chapterIndex", "chapter_idx" },
}
