/* Today's spelling OCR correct/incorrect counts from image_uploads.

   Completing spelling writes correct 0 and incorrect = word count before the
   photos are reviewed. The reviewed result is the task suffix (-✓ / -X) and,
   for a paper sheet, missed_words. This tally matches spelling_ocr_report.html.
*/
(function (root) {
    function photoKind(status) {
        const value = String(status || '');
        if (value === '✓' || value === 'checkmark' || value.toLowerCase() === 'correct') return 'correct';
        if (value.toLowerCase() === 'unverified') return 'unverified';
        return 'incorrect';
    }

    function torontoTodayYmd() {
        return new Intl.DateTimeFormat('en-CA', {
            timeZone: 'America/Toronto',
            year: 'numeric',
            month: '2-digit',
            day: '2-digit'
        }).format(new Date());
    }

    function addTorontoDays(ymd, deltaDays) {
        const parts = ymd.split('-').map(Number);
        const base = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2], 17, 0, 0));
        base.setUTCDate(base.getUTCDate() + deltaDays);
        return new Intl.DateTimeFormat('en-CA', {
            timeZone: 'America/Toronto',
            year: 'numeric',
            month: '2-digit',
            day: '2-digit'
        }).format(base);
    }

    function missedList(value) {
        if (!value) return null;
        if (typeof value === 'string') {
            try { value = JSON.parse(value); } catch (e) { return null; }
        }
        if (!Array.isArray(value)) return null;
        const seen = {};
        const out = [];
        value.forEach((item) => {
            const word = String(item || '').trim();
            const key = word.toLowerCase();
            if (!word || seen[key]) return;
            seen[key] = true;
            out.push(word);
        });
        return out;
    }

    function sheetWordList(task) {
        const parts = String(task || '').trim().split('-');
        if (parts.length < 5) return [];
        const gp = (parts[0] || '').toLowerCase();
        const isCopy = gp === 'engspellingocrxtra' || gp === 'frspellingocrxtra'
            || gp === 'engspellingcopy' || gp === 'frspellingcopy';
        const isList = gp === 'engspellingocrpaper' || gp === 'frspellingocrpaper';
        if (!isCopy && !isList) return [];
        let index = 1;
        if (/^\d{4}$/.test(parts[1]) && /^\d{2}$/.test(parts[2]) && /^\d{2}$/.test(parts[3])) index = 4;
        let raw = '';
        if (isCopy) {
            if (!/^r\d+$/i.test(parts[index] || '')) return [];
            if (!/^sheet$/i.test(parts[index + 1] || '')) return [];
            raw = parts.slice(index + 2, -1).join('-');
        } else {
            raw = parts.slice(index, -1).join('-');
        }
        return raw.split('|').map((item) => item.trim()).filter(Boolean);
    }

    function tallyTask(counts, task, status, missedWords) {
        const kind = status || photoKind(String(task || '').trim().split('-').pop());
        const words = sheetWordList(task);
        const missed = missedList(missedWords);
        if (kind === 'unverified') {
            counts.unverified += 1;
            return;
        }
        if (words.length && kind === 'correct') {
            counts.correct += words.length;
            return;
        }
        if (words.length && kind === 'incorrect' && missed && missed.length) {
            const incorrectN = Math.min(missed.length, words.length);
            counts.incorrect += incorrectN;
            counts.correct += Math.max(0, words.length - incorrectN);
            return;
        }
        if (kind === 'correct') counts.correct += 1;
        else counts.incorrect += 1;
    }

    function countTasks(tasks) {
        const counts = { correct: 0, incorrect: 0, unverified: 0 };
        (tasks || []).forEach((row) => tallyTask(counts, row.task, null, row.missed_words));
        return counts;
    }

    function taskDay(task) {
        const match = String(task || '').match(/^(?:Eng|Fr)SpellingOCR(?:Xtra|Paper)?-(\d{4}-\d{2}-\d{2})-/i);
        return match ? match[1] : null;
    }

    function gamePrefix(task) {
        return String(task || '').trim().split('-')[0].toLowerCase();
    }

    function languageOf(taskKey, task) {
        const title = String(taskKey || (task && task.title) || '');
        const url = String((task && task.url) || '').toLowerCase();
        if (/^fr\b/i.test(title) || /french/i.test(title) || url.includes('french') || /(?:^|[?&])lang=fr(?:&|$)/.test(url)) {
            return 'fr';
        }
        if (/^eng\b/i.test(title) || /english/i.test(title) || url.includes('english') || /(?:^|[?&])lang=eng(?:&|$)/.test(url)) {
            return 'eng';
        }
        return null;
    }

    function prefixesFor(taskKey, task) {
        const launch = String((task && task.launch) || '');
        const lang = languageOf(taskKey, task);
        if (!lang) return [];
        const stem = lang === 'fr' ? 'fr' : 'eng';
        if (launch === 'spellingOCR') {
            return [stem + 'spellingocr', stem + 'spellingocrpaper', stem + 'spellingocrxtra'];
        }
        if (launch === 'spellingOCRPaper') return [stem + 'spellingocrpaper'];
        if (launch === 'spellingOCRXtra') return [stem + 'spellingocrxtra'];
        return [];
    }

    // Screen, paper, and extra photos for one language belong to that language's
    // spelling OCR task. A separate paper or extra task on the same list keeps its own photos.
    function scoresByTask(tasksByKey, rows) {
        const owner = {};
        Object.keys(tasksByKey || {}).forEach((key) => {
            const task = tasksByKey[key];
            const specific = String(task && task.launch) !== 'spellingOCR';
            prefixesFor(key, task).forEach((prefix) => {
                if (!owner[prefix] || specific) owner[prefix] = key;
            });
        });
        const buckets = {};
        (rows || []).forEach((row) => {
            const key = owner[gamePrefix(row && row.task)];
            if (!key) return;
            if (!buckets[key]) buckets[key] = [];
            buckets[key].push(row);
        });
        const scores = {};
        Object.keys(buckets).forEach((key) => {
            scores[key] = countTasks(buckets[key]);
        });
        return scores;
    }

    function answerCounts(taskKey, task, scores) {
        const scored = scores && scores[taskKey];
        if (scored && (scored.correct + scored.incorrect + scored.unverified) > 0) {
            return {
                correct: scored.correct,
                incorrect: scored.incorrect,
                show: scored.correct + scored.incorrect > 0
            };
        }
        return {
            correct: Number(task && task.correct) || 0,
            incorrect: Number(task && task.incorrect) || 0,
            show: true
        };
    }

    async function fetchToday(supabaseUrl, supabaseKey, profile) {
        const base = String(supabaseUrl || '').replace(/\/$/, '');
        const who = encodeURIComponent(profile);
        const headers = { apikey: supabaseKey, Authorization: 'Bearer ' + supabaseKey };
        const ymd = torontoTodayYmd();
        const dated = encodeURIComponent('%SpellingOCR%' + ymd + '%');
        const any = encodeURIComponent('%SpellingOCR-%');
        const start = encodeURIComponent(ymd + 'T00:00:00');
        const end = encodeURIComponent(addTorontoDays(ymd, 1) + 'T00:00:00');
        const select = 'select=id,task,missed_words';
        const [datedRes, legacyRes] = await Promise.all([
            fetch(base + '/rest/v1/image_uploads?profile=eq.' + who + '&task=ilike.' + dated + '&' + select, { headers }),
            fetch(base + '/rest/v1/image_uploads?profile=eq.' + who + '&task=ilike.' + any + '&capture_date_time=gte.' + start + '&capture_date_time=lt.' + end + '&' + select, { headers })
        ]);
        if (!datedRes.ok) throw new Error('image_uploads: ' + datedRes.status);
        const datedRows = await datedRes.json();
        const legacyRows = legacyRes.ok ? await legacyRes.json() : [];
        const seen = {};
        const out = [];
        function add(row, undatedOnly) {
            if (!row || !row.task) return;
            const day = taskDay(row.task);
            if (undatedOnly) {
                if (day) return;
            } else if (day !== ymd) {
                return;
            }
            const id = row.id != null ? 'id:' + row.id : row.task;
            if (seen[id]) return;
            seen[id] = true;
            out.push(row);
        }
        (Array.isArray(datedRows) ? datedRows : []).forEach((row) => add(row, false));
        (Array.isArray(legacyRows) ? legacyRows : []).forEach((row) => add(row, true));
        return out;
    }

    root.SpellingOcrCounts = {
        countTasks: countTasks,
        scoresByTask: scoresByTask,
        answerCounts: answerCounts,
        fetchToday: fetchToday
    };
})(typeof window !== 'undefined' ? window : globalThis);
