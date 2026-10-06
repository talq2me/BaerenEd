
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

        function formatTorontoLong(ymd) {
            const parts = ymd.split('-').map(Number);
            const ms = Date.UTC(parts[0], parts[1] - 1, parts[2], 17, 0, 0);
            return new Date(ms).toLocaleDateString('en-US', {
                timeZone: 'America/Toronto',
                weekday: 'long',
                year: 'numeric',
                month: 'long',
                day: 'numeric'
            });
        }

        function countTasks(tasks) {
            let correct = 0;
            let incorrect = 0;
            let unverified = 0;
            (tasks || []).forEach((row) => {
                const parts = String(row.task || '').trim().split('-');
                if (parts.length < 4) return;
                const kind = photoKind(parts[parts.length - 1]);
                if (kind === 'correct') correct += 1;
                else if (kind === 'unverified') unverified += 1;
                else incorrect += 1;
            });
            return { correct, incorrect, unverified };
        }

        async function loadGameCounts() {
            const supabaseUrl = localStorage.getItem('supabaseUrl');
            const supabaseKey = localStorage.getItem('supabaseKey');
            const slots = document.querySelectorAll('.game-count');
            const ymd = torontoTodayYmd();
            document.getElementById('dayNote').textContent = `Today · ${formatTorontoLong(ymd)}`;
            document.querySelectorAll('a.game-button').forEach((link) => {
                const url = new URL(link.getAttribute('href'), window.location.href);
                url.searchParams.set('ymd', ymd);
                link.href = `spelling_ocr_detail.html?${url.searchParams.toString()}`;
            });
            if (!supabaseUrl || !supabaseKey) {
                slots.forEach((el) => { el.textContent = 'Set Supabase on the main page'; });
                return;
            }
            const headers = {
                'apikey': supabaseKey,
                'Authorization': `Bearer ${supabaseKey}`
            };
            await Promise.all([...slots].map(async (el) => {
                const profile = el.dataset.profile;
                const game = el.dataset.game;
                    const prefixes = [game];
                    if (game.endsWith('SpellingOCR')) {
                        prefixes.push(game.replace(/OCR$/, 'OCRXtra'));
                        prefixes.push(game.replace(/OCR$/, 'OCRPaper'));
                    }
                try {
                    const batches = await Promise.all(prefixes.map(async (prefix) => {
                        const pattern = encodeURIComponent(`${prefix}-${ymd}-`) + '%25';
                        const response = await fetch(
                            `${supabaseUrl}/rest/v1/image_uploads?profile=eq.${profile}&task=ilike.${pattern}&select=task`,
                            { headers }
                        );
                        if (!response.ok) throw new Error(await response.text());
                        const dated = await response.json();
                        const legacyAny = encodeURIComponent(`${prefix}-`) + '%25';
                        const legacyDated = encodeURIComponent(`${prefix}-____-__-__-`) + '%25';
                        const start = encodeURIComponent(`${ymd}T00:00:00`);
                        const end = encodeURIComponent(`${addTorontoDays(ymd, 1)}T00:00:00`);
                        const legacyResponse = await fetch(
                            `${supabaseUrl}/rest/v1/image_uploads?profile=eq.${profile}&task=ilike.${legacyAny}&task=not.ilike.${legacyDated}&capture_date_time=gte.${start}&capture_date_time=lt.${end}&select=task`,
                            { headers }
                        );
                        const legacy = legacyResponse.ok ? await legacyResponse.json() : [];
                        return dated.concat(legacy);
                    }));
                    const counts = countTasks(batches.flat());
                    const total = counts.correct + counts.incorrect + counts.unverified;
                    const unverifiedNote = counts.unverified ? `, ${counts.unverified} unverified` : '';
                    el.textContent = total
                        ? `${counts.correct} correct, ${counts.incorrect} incorrect${unverifiedNote}`
                        : 'Nothing today';
                } catch (error) {
                    console.error('OCR count failed', profile, game, error);
                    el.textContent = 'Could not load counts';
                }
            }));
        }

        loadGameCounts();
    