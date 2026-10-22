# Cover art provenance

The BBC Micro Classics bookshelf shows one cover per game, from `Covers/<game id>.jpg`.
A game without a cover file gets a typographic placeholder, drawn by the app, and so does
the BBCMicro.co.uk archive book, which uses no third-party logo or artwork.

The covers are scans of the original BBC Micro packaging. They were supplied by the
project owner on 22 October 2026 (the originals aren't in the repository) and scaled to
800 pixels high for the app. Deleting a cover's file brings back the placeholder;
nothing else needs to change.

| Rank | Game (archive ID) | Asset | Edition shown | Source |
|---:|---|---|---|---|
| 1 | Elite [co-pro] (3471) | elite-copro.jpg | Acornsoft BBC Micro release | supplied by owner |
| 2 | Chuckie Egg (25) | chuckie-egg.jpg | A&F Software, BBC Micro | supplied by owner |
| 3 | Repton 3 (425) | repton-3.jpg | Superior Software, BBC Micro | supplied by owner |
| 4 | Exile [64K] (709) | exile-64k.jpg | Superior Software, BBC Micro | supplied by owner |
| 5 | Starship Command (35) | starship-command.jpg | Acornsoft, BBC Micro | supplied by owner |
| 6 | Thrust (432) | thrust.jpg | Superior Software, BBC Micro | supplied by owner |
| 7 | Citadel (290) | citadel.jpg | Superior Software, BBC Micro | supplied by owner |
| 8 | Repton 2 (298) | repton-2.jpg | Superior Software, BBC Micro | supplied by owner |
| 9 | Revs (267) | revs.jpg | Acornsoft, BBC Micro | supplied by owner |
| 10 | Repton (266) | repton.jpg | Superior Software, BBC Micro | supplied by owner |
| 11 | Imogen (512) | imogen.jpg | Micro Power, BBC Micro | supplied by owner |
| 12 | Codename: Droid (564) | codename-droid.jpg | Superior Software, BBC Micro | supplied by owner |
| 13 | Firetrack (598) | firetrack.jpg | Electric Dreams, BBC Micro | supplied by owner |
| 14 | Arcadians (20) | arcadians.jpg | Acornsoft, BBC Micro | supplied by owner |
| 15 | Mr Ee (85) | mr-ee.jpg | Micro Power, BBC Micro | supplied by owner |
| 16 | Zalaga (54) | zalaga.jpg | Aardvark, BBC Micro | supplied by owner |
| 17 | Castle Quest (238) | castle-quest.jpg | Micro Power, BBC Micro | supplied by owner |
| 18 | Galaforce (438) | galaforce.jpg | Superior Software, BBC Micro | supplied by owner |
| 19 | Skirmish (822) | skirmish.jpg | Go-Dax, BBC Micro | supplied by owner |
| 20 | Snapper (14) | snapper.jpg | Acornsoft, BBC Micro | supplied by owner |

### Author's Picks

Seven of the Author's Picks are also in the top 20 and share their covers. The others:

| Game (archive ID) | Asset | Edition shown | Source |
|---|---|---|---|
| Holed Out!! (1249) | holed-out.jpg | 4th Dimension, BBC Micro | supplied by owner |
| SimCity (934) | simcity.jpg | Superior Software, BBC Micro | supplied by owner |
| Planetoid (11) | planetoid.jpg | Acornsoft, BBC Micro | supplied by owner |
| Ravenskull (412) | ravenskull.jpg | Superior Software, BBC Micro | supplied by owner |
| U.I.M. (1385) | uim.jpg | 4th Dimension, BBC Micro | supplied by owner |
| Barbarian (757) | barbarian.jpg | Superior Software, BBC Micro | supplied by owner |
| Nevryon (1183) | nevryon.jpg | 4th Dimension, BBC Micro | supplied by owner |
| Stryker's Run [enhanced] (3286) | strykers-run-128k.jpg | Superior Software, BBC Micro | supplied by owner |
| Repton: Around the World in 40 Screens (812) | repton-around-the-world.jpg | Superior Software, BBC Micro | supplied by owner |
| Repton Infinity (3571) | repton-infinity.jpg | Superior Software, BBC Micro | supplied by owner |
| Doctor Who and the Mines of Terror (2972) | doctor-who-mines-of-terror.jpg | Micro Power, BBC Micro | supplied by owner |
| The Way of the Exploding Fist (341) | exploding-fist.jpg | Melbourne House, BBC Micro | supplied by owner |
| Knight Lore (208) | knight-lore.jpg | Ultimate Play The Game, BBC Micro | supplied by owner |

## Disc fingerprints

`Data/classics.json` lists the SHA-256 of each game's disc as downloaded from its
BBCMicro.co.uk page on 22 October 2026. Each was booted headlessly (`beeb --disc … --boot`)
on the machine the catalogue gives it, and reached its title screen. The disc images
themselves are not in the repository, the tests or the app. To check or add a fingerprint,
download the disc from its game page and run `shasum -a 256` on it.
