"""Tests de bout en bout de H42N42 dans un vrai navigateur (Playwright + Chromium).

Le temps du jeu est piloté par l'horloge simulée de Playwright : les threads Lwt
reposent sur setTimeout, on peut donc figer la partie, agir à la souris, puis
avancer le temps d'une durée exacte. La simulation longue (6 min) tourne en temps réel.

    H42N42_URL=http://localhost:8080 python3 -m pytest tests/e2e -v
"""

import math
import os
import re
import time
import urllib.request

import pytest
from playwright.sync_api import sync_playwright

URL = os.environ.get("H42N42_URL", "http://localhost:8080/")
CHROMIUM = os.environ.get("CHROMIUM_PATH") or None

AREA_W, AREA_H = 900, 600
RIVER_H, HOSPITAL_H = 60, 80
CREET_D = 40.0

COLORS = {
    "healthy": "rgb(76, 175, 80)",
    "sick": "rgb(255, 152, 0)",
    "berserk": "rgb(244, 67, 54)",
    "mean": "rgb(156, 39, 176)",
}

# Lit l'état visible de chaque Creet : identifiant stable, état, diamètre et centre
# dans le repère de la zone de jeu.
SAMPLE_JS = """() => {
    window.__uids = window.__uids || new WeakMap();
    window.__next_uid = window.__next_uid || 0;
    return [...document.querySelectorAll('.game-area .creet')].map(e => {
        if (!window.__uids.has(e)) window.__uids.set(e, window.__next_uid++);
        const d = parseFloat(e.style.width);
        const state = ['healthy', 'sick', 'berserk', 'mean'].find(c => e.classList.contains(c));
        return { uid: window.__uids.get(e), state, d,
                 x: parseFloat(e.style.left) + d / 2, y: parseFloat(e.style.top) + d / 2,
                 classes: e.className };
    });
}"""


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path=CHROMIUM)
        yield b
        b.close()


class Game:
    """Une partie ouverte dans un onglet, horloge figée une seconde après le chargement."""

    def __init__(self, page):
        self.page = page
        self.errors = []
        page.on("pageerror", lambda e: self.errors.append(str(e)))
        page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        page.clock.install(time=0)
        page.goto(URL)
        page.wait_for_selector(".game-area .creet")
        page.clock.pause_at(1)  # en secondes : t = 1 s
        box = page.locator(".game-area").bounding_box()
        self.origin = (box["x"] + 2, box["y"] + 2)  # bordure de 2 px

    def run(self, ms):
        self.page.clock.run_for(ms)

    def creets(self):
        return self.page.evaluate(SAMPLE_JS)

    def by_uid(self, uid):
        return next((c for c in self.creets() if c["uid"] == uid), None)

    def screen(self, x, y):
        return (self.origin[0] + x, self.origin[1] + y)

    def grab(self, creet):
        self.page.mouse.move(*self.screen(creet["x"], creet["y"]))
        self.page.mouse.down()

    def move_to(self, x, y):
        self.page.mouse.move(*self.screen(x, y), steps=8)

    def drag(self, creet, x, y):
        self.grab(creet)
        self.move_to(x, y)
        self.page.mouse.up()

    def stats(self):
        return self.page.inner_text(".stats")


@pytest.fixture
def game(browser):
    context = browser.new_context(viewport={"width": 1400, "height": 900})
    g = Game(context.new_page())
    yield g
    context.close()


def dist(a, b):
    return math.hypot(a["x"] - b["x"], a["y"] - b["y"])


def far_healthy(game, n):
    """Les n Creets Sains les plus éloignés des bords (évite les rebonds pendant une mesure)."""
    healthy = [c for c in game.creets() if c["state"] == "healthy"]
    margin = lambda c: min(c["x"], AREA_W - c["x"], c["y"] - RIVER_H, AREA_H - HOSPITAL_H - c["y"])
    return sorted(healthy, key=margin, reverse=True)[:n]


# ================================================================
# Serveur Eliom
# ================================================================

def test_page_generated_by_eliom():
    html = urllib.request.urlopen(URL).read().decode()
    assert html.startswith("<!DOCTYPE html>")
    assert "data-eliom-id" in html, "page produite par Eliom_content.Html"
    assert re.search(r'<script[^>]*src="[^"]*h42n42\.js"', html), "programme client js_of_ocaml"
    assert 'class="game-area' in html and 'style="width:900px;height:600px"' in html
    for path in ("h42n42.js", "css/style.css", "favicon.svg"):
        with urllib.request.urlopen(URL + path) as r:
            assert r.status == 200, path
    with urllib.request.urlopen(URL + "h42n42.js") as r:
        assert len(r.read()) > 100_000, "JavaScript compilé depuis OCaml"


def test_no_errors_in_browser_console(browser):
    page = browser.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: errors.append(m.text) if m.type in ("error", "warning") else None)
    page.goto(URL)
    page.wait_for_timeout(3000)
    page.close()
    assert errors == []


# ================================================================
# Population, couleurs et déplacements
# ================================================================

def test_initial_population(game):
    creets = game.creets()
    assert len(creets) == 7
    assert all(c["state"] == "healthy" for c in creets)
    assert all(c["d"] == CREET_D for c in creets)
    assert all(RIVER_H < c["y"] - c["d"] / 2 and c["y"] + c["d"] / 2 < AREA_H - HOSPITAL_H for c in creets)
    assert game.stats().startswith("Healthy 7 · Sick 0 · Berserk 0 · Mean 0")


def test_distinct_colors(game):
    colors = game.page.evaluate("""() => ['healthy','sick','berserk','mean'].map(cls => {
        const e = document.createElement('div'); e.className = 'creet ' + cls;
        document.querySelector('.game-area').appendChild(e);
        const c = getComputedStyle(e).backgroundColor; e.remove(); return c; })""")
    assert colors == [COLORS[s] for s in ("healthy", "sick", "berserk", "mean")]
    assert len(set(colors)) == 4


def test_straight_line_constant_speed(game):
    tracked = far_healthy(game, 3)
    before = {c["uid"]: c for c in tracked}
    game.run(500)
    mid = {c["uid"]: game.by_uid(c["uid"]) for c in tracked}
    game.run(500)
    for uid, start in before.items():
        middle, end = mid[uid], game.by_uid(uid)
        d1, d2 = dist(start, middle), dist(middle, end)
        assert 40 < d1 < 80 and abs(d1 - d2) < 4, "vitesse constante (~2 px par tick)"
        # Trois points alignés : ligne droite
        cross = (middle["x"] - start["x"]) * (end["y"] - start["y"]) - (middle["y"] - start["y"]) * (end["x"] - start["x"])
        assert abs(cross) / (d1 + d2) < 2.0


def test_spawn_every_5_seconds(game):
    # Le jeu démarre au chargement, entre t = 0 et t = 1 s : la première naissance tombe dans [5 s, 6 s[.
    assert len(game.creets()) == 7
    game.run(3000)  # t = 4 s
    assert len(game.creets()) == 7
    game.run(2000)  # t = 6 s
    creets = game.creets()
    assert len(creets) == 8
    newborn = max(creets, key=lambda c: c["uid"])
    assert newborn["state"] == "healthy"
    game.run(5000)
    assert len(game.creets()) == 9


def test_global_acceleration(game):
    # Le joueur garde un Creet Sain en main pour que la partie ne se termine pas.
    game.grab(far_healthy(game, 1)[0])
    game.move_to(450, 300)
    game.run(60_000 - 1000)
    multiplier = float(re.search(r"Speed ×([\d.]+)", game.stats()).group(1))
    assert 1.15 < multiplier < 1.25, "≈ 1.003^60 après une minute"


# ================================================================
# Glisser-déposer
# ================================================================

def test_drag_follows_mouse_and_resumes(game):
    creet = far_healthy(game, 1)[0]
    game.grab(creet)
    game.move_to(450, 300)
    held = game.by_uid(creet["uid"])
    assert "dragged" in held["classes"], "retour visuel pendant le glisser"
    assert abs(held["x"] - 450) < 1.5 and abs(held["y"] - 300) < 1.5
    game.run(1000)
    still = game.by_uid(creet["uid"])
    assert abs(still["x"] - 450) < 1.5 and abs(still["y"] - 300) < 1.5, "immobile tant qu'il est tenu"
    game.page.mouse.up()
    dropped = game.by_uid(creet["uid"])
    assert "dragged" not in dropped["classes"]
    game.run(300)
    assert dist(dropped, game.by_uid(creet["uid"])) > 20, "reprend son mouvement depuis le point de dépôt"


def test_dragged_creet_is_invulnerable_in_river(game):
    creet = far_healthy(game, 1)[0]
    game.grab(creet)
    game.move_to(450, 25)
    game.run(3000)
    assert game.by_uid(creet["uid"])["state"] == "healthy", "invulnérable tant qu'il est tenu"
    game.page.mouse.up()
    game.run(50)
    assert game.by_uid(creet["uid"])["state"] == "sick", "contaminé dès qu'il est lâché dans la rivière"


def test_dragged_creet_is_invulnerable_to_contact(game):
    sick, healthy = far_healthy(game, 2)
    game.drag(sick, 450, 25)
    game.run(50)
    assert game.by_uid(sick["uid"])["state"] == "sick"
    game.drag(game.by_uid(sick["uid"]), 450, 300)
    # Le Sain est tenu exactement sur le Malade pendant 3 s (≈ 190 contacts à 2 %).
    game.grab(game.by_uid(healthy["uid"]))
    game.move_to(game.by_uid(sick["uid"])["x"], game.by_uid(sick["uid"])["y"])
    for _ in range(30):
        game.move_to(game.by_uid(sick["uid"])["x"], game.by_uid(sick["uid"])["y"])
        assert dist(game.by_uid(sick["uid"]), game.by_uid(healthy["uid"])) < 40
        game.run(100)
    assert game.by_uid(healthy["uid"])["state"] == "healthy"
    game.page.mouse.up()


def test_contaminated_creet_changes_color_and_slows_down(game):
    sick, healthy = far_healthy(game, 2)
    game.drag(sick, 450, 25)
    game.run(20)
    contaminated = game.by_uid(sick["uid"])
    assert contaminated["state"] == "sick" and "infected" in contaminated["classes"], "retour visuel"
    color = game.page.evaluate("uid => getComputedStyle([...document.querySelectorAll('.game-area .creet')]"
                               ".find(e => window.__uids.get(e) === uid)).backgroundColor", sick["uid"])
    assert color == COLORS["sick"]
    # Mesure des vitesses au centre de la zone, loin des bords et l'un de l'autre.
    game.drag(contaminated, 300, 300)
    game.drag(game.by_uid(healthy["uid"]), 600, 300)
    a0, b0 = game.by_uid(sick["uid"]), game.by_uid(healthy["uid"])
    game.run(800)
    ratio = dist(a0, game.by_uid(sick["uid"])) / dist(b0, game.by_uid(healthy["uid"]))
    assert abs(ratio - 0.85) < 0.03, f"Malade 15 % plus lent (ratio {ratio:.3f})"


def test_hospital_heals_dropped_sick_creet(game):
    creet = far_healthy(game, 1)[0]
    game.drag(creet, 450, 25)
    game.run(20)
    assert game.by_uid(creet["uid"])["state"] == "sick"
    game.drag(game.by_uid(creet["uid"]), 450, 300)
    assert game.by_uid(creet["uid"])["state"] == "sick", "lâché hors de l'hôpital : toujours malade"
    game.drag(game.by_uid(creet["uid"]), 450, 565)
    healed = game.by_uid(creet["uid"])
    assert healed["state"] == "healthy" and "healed" in healed["classes"]
    # Vitesse normale retrouvée (mesurée au centre, loin des bords)
    game.drag(healed, 450, 300)
    start = game.by_uid(creet["uid"])
    game.run(500)
    assert dist(start, game.by_uid(creet["uid"])) > 55


def test_drop_outside_play_area(game):
    creet = far_healthy(game, 1)[0]
    game.drag(creet, -90, 300)
    dropped = game.by_uid(creet["uid"])
    assert abs(dropped["x"] + 90) < 1.5, "déposé hors de la zone"
    box = game.page.evaluate("uid => [...document.querySelectorAll('.game-area .creet')]"
                             ".find(e => window.__uids.get(e) === uid).getBoundingClientRect().right", creet["uid"])
    assert box < game.origin[0] and box > 0, "toujours visible hors de la zone"
    game.run(16)
    assert abs(game.by_uid(creet["uid"])["x"] - dropped["x"]) < 3, "pas de téléportation"
    for _ in range(60):
        game.run(1000)
        c = game.by_uid(creet["uid"])
        if 0 < c["x"] < AREA_W and 0 < c["y"] < AREA_H:
            break
    assert 0 < c["x"] < AREA_W and 0 < c["y"] < AREA_H, "revient dans la zone"


# ================================================================
# Fin de partie
# ================================================================

def test_game_over_when_no_healthy_creet_left(game):
    assert not game.page.is_visible(".game-over")
    for creet in game.creets():
        game.drag(creet, creet["x"], 20)
    game.run(200)
    assert game.page.is_visible(".game-over")
    assert game.page.inner_text(".game-over-text") == "GAME OVER"
    assert "Healthy 0" in game.stats()
    snapshot = lambda: [(c["uid"], c["state"], c["x"], c["y"], c["d"]) for c in game.creets()]
    frozen = snapshot()
    game.run(5000)
    assert snapshot() == frozen, "la simulation est arrêtée et plus rien ne naît"
    game.page.clock.resume()
    game.page.click(".restart")
    game.page.wait_for_selector(".game-area .creet")
    assert len(game.creets()) == 7
    assert not game.page.is_visible(".game-over")


# ================================================================
# Simulation longue (temps réel) : Berserk, Mean, hôpital, poursuite
# ================================================================

@pytest.fixture
def live_game(browser):
    """Une partie en temps réel (horloge du navigateur non simulée)."""
    context = browser.new_context(viewport={"width": 1400, "height": 900})
    g = Game.__new__(Game)
    g.page, g.errors = context.new_page(), []
    g.page.on("pageerror", lambda e: g.errors.append(str(e)))
    g.page.on("console", lambda m: g.errors.append(m.text) if m.type == "error" else None)
    g.page.goto(URL)
    g.page.wait_for_selector(".game-area .creet")
    box = g.page.locator(".game-area").bounding_box()
    g.origin = (box["x"] + 2, box["y"] + 2)
    yield g
    context.close()


def test_long_simulation(live_game):
    """Le joueur tient un Creet Sain (invulnérable) pour que la partie dure ; on observe
    pendant 6 minutes, en temps réel, l'état de tous les Creets à chaque seconde."""
    game = live_game
    keeper = far_healthy(game, 1)[0]
    game.grab(keeper)
    game.move_to(450, 300)
    timeline = []  # (seconde, liste des Creets)
    t0 = time.monotonic()
    for second in range(360):
        time.sleep(max(0.0, t0 + second + 1 - time.monotonic()))
        timeline.append((second, game.creets()))
    assert not game.page.is_visible(".game-over")

    history = {}
    for second, creets in timeline:
        for c in creets:
            history.setdefault(c["uid"], []).append((second, c))

    def first(uid, state):
        return next((s for s, c in history[uid] if c["state"] == state), None)

    berserks = [uid for uid in history if first(uid, "berserk") is not None]
    means = [uid for uid in history if first(uid, "mean") is not None]
    assert berserks, "des Creets sont devenus Berserk"
    assert means, "des Creets sont devenus Mean"
    assert not set(berserks) & set(means), "Berserk OU Mean, jamais les deux"

    last_second = timeline[-1][0]
    for uid in berserks:
        start = first(uid, "berserk")
        assert all(c["state"] == "berserk" for s, c in history[uid] if s >= start), "reste Berserk"
        for s, c in (sample for sample in history[uid] if sample[0] >= start):
            steps = (s - start) // 10
            expected = CREET_D * 1.1 ** steps
            if (s - start) % 10 not in (0, 9):  # évite l'incertitude d'une seconde au palier
                assert abs(c["d"] - expected) < 0.2, f"Berserk +10 % toutes les 10 s ({c['d']} ≠ {expected:.1f})"
        death = history[uid][-1][0] + 1
        if start + 152 <= last_second:
            assert 148 <= death - start <= 152, f"Berserk meurt à 4× sa taille, ~2 min 30 ({death - start} s)"

    for uid in means:
        start = first(uid, "mean")
        assert all(c["state"] == "mean" for s, c in history[uid] if s >= start), "reste Mean"
        assert all(abs(c["d"] - CREET_D * 0.85) < 0.1 for s, c in history[uid] if s >= start), "rétréci de 15 %"
        death = history[uid][-1][0] + 1
        if start + 62 <= last_second:
            assert 59 <= death - start <= 61, f"Mean meurt après une minute ({death - start} s)"

    # Seule la mutation fait mourir : un Creet Sain ou Malade ne disparaît jamais.
    for uid, samples in history.items():
        if samples[-1][0] < last_second:
            assert samples[-1][1]["state"] in ("berserk", "mean"), "seuls Berserk et Mean meurent"

    # Un Malade qui entre seul dans l'hôpital n'est pas guéri.
    wandered = [(uid, s) for uid, samples in history.items() for s, c in samples
                if c["state"] == "sick" and c["y"] >= AREA_H - HOSPITAL_H]
    assert wandered, "des Malades ont traversé l'hôpital"
    for uid, s in wandered:
        later = [c["state"] for t, c in history[uid] if t > s]
        assert "healthy" not in later, "pas de guérison sans le joueur"

    # Les Mean se dirigent vers le Creet Sain le plus proche (hors cas où ils sont déjà dessus).
    toward = total = 0
    for (s1, creets1), (s2, creets2) in zip(timeline, timeline[1:]):
        now = {c["uid"]: c for c in creets2}
        targets = [c for c in creets1 if c["state"] == "healthy"]
        for m in (c for c in creets1 if c["state"] == "mean" and c["uid"] in now):
            target = min(targets, key=lambda c: dist(c, m))
            if dist(m, target) > 60:
                total += 1
                move_x, move_y = now[m["uid"]]["x"] - m["x"], now[m["uid"]]["y"] - m["y"]
                toward += move_x * (target["x"] - m["x"]) + move_y * (target["y"] - m["y"]) > 0
    assert total > 0 and toward / total > 0.9, f"poursuite ({toward}/{total})"

    # Berserk et Mean ne peuvent pas être saisis.
    game.page.mouse.up()
    for uid in (berserks + means):
        target = next((c for c in game.creets() if c["uid"] == uid), None)
        if target is None:
            continue
        game.grab(target)
        pointer = {"x": target["x"] + 150, "y": min(target["y"] + 80, AREA_H - 10)}
        game.move_to(pointer["x"], pointer["y"])
        after = game.by_uid(uid)
        assert "dragged" not in after["classes"]
        assert dist(after, pointer) > 60, "ne suit pas la souris"
        game.page.mouse.up()
        break
    else:
        pytest.fail("aucun Berserk ou Mean vivant à la fin pour tester la saisie")

    assert game.errors == []
