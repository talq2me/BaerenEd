-- Replace the park prize with extra Minecraft time. Same odds.
UPDATE reward_spinner
SET name = 'Extra Minecraft time'
WHERE name = 'Trip to the park';

UPDATE user_data
SET prize_unlocked = 'Extra Minecraft time'
WHERE prize_unlocked = 'Trip to the park';
