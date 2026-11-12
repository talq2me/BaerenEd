/**
 * Early-week jumble scaffolding: syllables → letters (shown) → blind jumble.
 * Driven by school-list JSON { start_date, lang, words }.
 */
(function (global) {
    function parseList(raw) {
        if (global.SpellingPool && typeof SpellingPool.parseWords === 'function') {
            return SpellingPool.parseWords(raw);
        }
        const data = typeof raw === 'string' ? JSON.parse(raw) : raw;
        if (data && Array.isArray(data.words)) {
            return {
                words: data.words,
                lang: data.lang || null,
                startDate: data.start_date || data.startDate || null
            };
        }
        if (Array.isArray(data) && data.length && data[0] && data[0].word) {
            return { words: data, lang: null, startDate: null };
        }
        return { words: [], lang: null, startDate: null };
    }

    function torontoTodayYmd() {
        return new Intl.DateTimeFormat('en-CA', {
            timeZone: 'America/Toronto',
            year: 'numeric',
            month: '2-digit',
            day: '2-digit'
        }).format(new Date());
    }

    function parseYmd(ymd) {
        const m = String(ymd || '').trim().match(/^(\d{4})-(\d{2})-(\d{2})$/);
        if (!m) return null;
        return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    }

    /** Calendar days since start_date in Toronto (0 = first day). Null if missing/invalid. */
    function daysSinceStart(startDate) {
        const start = parseYmd(startDate);
        const today = parseYmd(torontoTodayYmd());
        if (start == null || today == null) return null;
        return Math.floor((today - start) / 86400000);
    }

    /**
     * AM English lists get 2 scaffold days; all other school lists get 3.
     */
    function scaffoldDayCount(fileName, lang) {
        const f = String(fileName || '').toLowerCase();
        if (f.includes('englishwordsam') || f.includes('english_words_am')) return 2;
        if ((f.includes('english') || f.includes('eng')) && f.includes('am') && !f.includes('bm') && !f.includes('te')) {
            return 2;
        }
        if (String(lang || '').toLowerCase().startsWith('en') && /am\.json$/.test(f)) return 2;
        return 3;
    }

    function isScaffoldActive(startDate, dayCount) {
        const d = daysSinceStart(startDate);
        if (d == null || d < 0) return false;
        return d < dayCount;
    }

    function hasValidSyllables(entry) {
        if (!entry || !Array.isArray(entry.syllables) || !entry.syllables.length) return false;
        return entry.syllables.join('').toLowerCase() === String(entry.word || '').toLowerCase();
    }

    /** @returns {Array<'syllables'|'letters'|'blind'>} */
    function roundsForEntry(entry, scaffoldOn) {
        if (!scaffoldOn) return ['blind'];
        if (hasValidSyllables(entry)) return ['syllables', 'letters', 'blind'];
        return ['letters', 'blind'];
    }

    /**
     * Decoy letters with no duplicates among extras (hard mode).
     * @param {string[]} targeted preferred decoys from sound swaps
     * @param {string} pool alphabet string
     * @param {number} minCount
     * @param {number} maxCount
     */
    function uniqueDecoys(targeted, pool, minCount, maxCount) {
        const extras = [];
        const used = new Set();
        function add(ch) {
            if (ch == null || ch === '') return;
            const c = String(ch);
            if (used.has(c)) return;
            used.add(c);
            extras.push(c);
        }
        (targeted || []).forEach(add);
        const shuffled = String(pool || '').split('').sort(function () { return Math.random() - 0.5; });
        for (let i = 0; extras.length < maxCount && i < shuffled.length; i++) {
            add(shuffled[i]);
        }
        return extras.slice(0, Math.max(minCount, Math.min(maxCount, extras.length)));
    }

    global.SpellingJumbleScaffold = {
        parseList: parseList,
        torontoTodayYmd: torontoTodayYmd,
        daysSinceStart: daysSinceStart,
        scaffoldDayCount: scaffoldDayCount,
        isScaffoldActive: isScaffoldActive,
        hasValidSyllables: hasValidSyllables,
        roundsForEntry: roundsForEntry,
        uniqueDecoys: uniqueDecoys
    };
})(typeof window !== 'undefined' ? window : globalThis);
