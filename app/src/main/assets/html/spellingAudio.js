/**
 * Preload and play spelling word/sentence clips from entry.audio URLs.
 * Keeps Audio elements in memory for the current word so Replay does not re-fetch.
 * Falls back to the caller's TTS when clips are missing or fail.
 *
 * Expected JSON shape:
 *   { "word": "...", "sentence": "...", "audio": { "word": "https://...ogg", "sentence": "https://...ogg" } }
 */
(function (global) {
    let wordAudio = null;
    let sentenceAudio = null;
    let playGen = 0;
    let loadedKey = '';

    function entryKey(entry) {
        var audio = entry && entry.audio;
        if (!audio || typeof audio !== 'object') return '';
        return String(audio.word || '') + '|' + String(audio.sentence || '');
    }

    function safePause(el) {
        if (!el) return;
        try {
            el.pause();
            el.currentTime = 0;
        } catch (e) { /* ignore */ }
    }

    function stop() {
        playGen += 1;
        safePause(wordAudio);
        safePause(sentenceAudio);
    }

    function release() {
        stop();
        wordAudio = null;
        sentenceAudio = null;
    }

    function loadOne(url) {
        return new Promise(function (resolve) {
            if (!url || typeof url !== 'string') {
                resolve(null);
                return;
            }
            var a = new Audio();
            a.preload = 'auto';
            var settled = false;
            function finish(ok) {
                if (settled) return;
                settled = true;
                resolve(ok ? a : null);
            }
            a.addEventListener('canplaythrough', function () { finish(true); }, { once: true });
            a.addEventListener('error', function () { finish(false); }, { once: true });
            a.src = url;
            try {
                a.load();
            } catch (e) {
                finish(false);
                return;
            }
            setTimeout(function () {
                finish(a.readyState >= 2);
            }, 8000);
        });
    }

    /**
     * @param {{ audio?: { word?: string, sentence?: string } }|null} entry
     * @returns {Promise<{ hasWord: boolean, hasSentence: boolean }>}
     */
    function preload(entry) {
        release();
        loadedKey = '';
        var audio = entry && entry.audio;
        if (!audio || typeof audio !== 'object') {
            return Promise.resolve({ hasWord: false, hasSentence: false });
        }
        var key = entryKey(entry);
        return Promise.all([loadOne(audio.word), loadOne(audio.sentence)]).then(function (pair) {
            wordAudio = pair[0];
            sentenceAudio = pair[1];
            loadedKey = key;
            return { hasWord: !!wordAudio, hasSentence: !!sentenceAudio };
        });
    }

    function ensurePreloaded(entry) {
        var key = entryKey(entry);
        if (key && key === loadedKey) {
            return Promise.resolve({ hasWord: !!wordAudio, hasSentence: !!sentenceAudio });
        }
        return preload(entry);
    }

    function playEl(el, rate) {
        return new Promise(function (resolve) {
            if (!el) {
                resolve(false);
                return;
            }
            var gen = playGen;
            var done = false;
            function finish(ok) {
                if (done) return;
                done = true;
                el.removeEventListener('ended', onEnded);
                el.removeEventListener('error', onErr);
                resolve(ok && gen === playGen);
            }
            function onEnded() { finish(true); }
            function onErr() { finish(false); }
            el.addEventListener('ended', onEnded, { once: true });
            el.addEventListener('error', onErr, { once: true });
            try {
                el.playbackRate = rate != null ? rate : 1;
            } catch (e) { /* ignore */ }
            try {
                el.currentTime = 0;
            } catch (e2) { /* ignore */ }
            var p = el.play();
            if (p && typeof p.then === 'function') {
                p.then(function () { /* playing */ }).catch(function () { finish(false); });
            }
        });
    }

    function clipFor(part) {
        return part === 'sentence' ? sentenceAudio : wordAudio;
    }

    /**
     * @param {Array<'word'|'sentence'>} parts
     * @param {{ rate?: number }|null} opts
     * @returns {Promise<boolean>} true if every part played from a clip
     */
    function playSequence(parts, opts) {
        var rate = opts && opts.rate != null ? opts.rate : 1;
        stop();
        var gen = playGen;
        var i = 0;
        function next() {
            if (gen !== playGen) return Promise.resolve(false);
            if (i >= parts.length) return Promise.resolve(true);
            var part = parts[i++];
            var el = clipFor(part);
            if (!el) return Promise.resolve(false);
            return playEl(el, rate).then(function (ok) {
                if (!ok || gen !== playGen) return false;
                return next();
            });
        }
        return next();
    }

    function playWord(opts) {
        return playSequence(['word'], opts);
    }

    function playSentence(opts) {
        return playSequence(['sentence'], opts);
    }

    /**
     * Play clip parts when available; otherwise call fallbackSpeak(onEnd).
     * @param {Array<'word'|'sentence'>} parts
     * @param {function(Function=): void} fallbackSpeak
     * @param {Function=} onEnd
     * @param {{ rate?: number }=} opts
     */
    function playOrSpeak(parts, fallbackSpeak, onEnd, opts) {
        var list = Array.isArray(parts) ? parts.filter(Boolean) : [];
        var ready = list.length > 0 && list.every(function (p) { return !!clipFor(p); });
        if (!ready) {
            if (typeof fallbackSpeak === 'function') fallbackSpeak(onEnd);
            else if (onEnd) onEnd();
            return Promise.resolve(false);
        }
        return playSequence(list, opts).then(function (ok) {
            if (ok) {
                if (onEnd) onEnd();
                return true;
            }
            if (typeof fallbackSpeak === 'function') fallbackSpeak(onEnd);
            else if (onEnd) onEnd();
            return false;
        });
    }

    /**
     * Default school-list prompt: word, then sentence if a sentence clip is loaded.
     */
    function playPrompt(entry, fallbackSpeak, onEnd, opts) {
        var parts = ['word'];
        if (sentenceAudio) parts.push('sentence');
        if (wordAudio) {
            return playOrSpeak(parts, fallbackSpeak, onEnd, opts);
        }
        if (typeof fallbackSpeak === 'function') fallbackSpeak(onEnd);
        else if (onEnd) onEnd();
        return Promise.resolve(false);
    }

    /**
     * Preload entry.audio (if any), play word[+sentence] clips, else TTS fallbackText.
     * @param {object} entry
     * @param {function(string, string, number=, Function=): void} readTextFn
     * @param {string} lang
     * @param {string} fallbackText full TTS string when clips are unavailable
     * @param {number=} rate
     * @param {Function=} onEnd
     */
    function speakEntryPrompt(entry, readTextFn, lang, fallbackText, rate, onEnd) {
        function fallback(cb) {
            if (typeof readTextFn === 'function') {
                readTextFn(fallbackText, lang, rate == null ? 0.8 : rate, cb);
            } else if (cb) {
                cb();
            }
        }
        return ensurePreloaded(entry).then(function () {
            return playPrompt(entry, fallback, onEnd);
        });
    }

    /**
     * Preload then play only the word clip (Replay). Falls back to TTS of entry.word.
     */
    function speakEntryWord(entry, readTextFn, lang, rate, onEnd, opts) {
        var word = entry && entry.word ? String(entry.word) : '';
        function fallback(cb) {
            if (typeof readTextFn === 'function') {
                readTextFn(word, lang, rate == null ? 0.8 : rate, cb);
            } else if (cb) {
                cb();
            }
        }
        return ensurePreloaded(entry).then(function () {
            if (wordAudio) {
                return playOrSpeak(['word'], fallback, onEnd, opts);
            }
            fallback(onEnd);
            return false;
        });
    }

    global.SpellingAudio = {
        preload: preload,
        ensurePreloaded: ensurePreloaded,
        release: release,
        stop: stop,
        playWord: playWord,
        playSentence: playSentence,
        playSequence: playSequence,
        playOrSpeak: playOrSpeak,
        playPrompt: playPrompt,
        speakEntryPrompt: speakEntryPrompt,
        speakEntryWord: speakEntryWord,
        hasWord: function () { return !!wordAudio; },
        hasSentence: function () { return !!sentenceAudio; }
    };
})(typeof window !== 'undefined' ? window : globalThis);
