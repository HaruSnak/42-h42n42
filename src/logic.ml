(* Logique pure du jeu — sans DOM, sans Lwt, sans état global.
   Toutes les fonctions reçoivent leurs paramètres explicitement pour être testables en natif.
   Le module est partagé : il est compilé pour le serveur (dimensions de la page),
   pour le client js_of_ocaml (simulation) et pour les tests natifs. *)

(* ================================================================
   CONSTANTES
   ================================================================ *)

(* Largeur de la zone de jeu en pixels. *)
let area_w        = 900

(* Hauteur de la zone de jeu en pixels. *)
let area_h        = 600

(* Hauteur de la rivière toxique en haut de la zone de jeu. *)
let river_h       = 60

(* Hauteur de la zone hôpital en bas de la zone de jeu. *)
let hospital_h    = 80

(* Rayon par défaut d'un Creet en pixels. *)
let creet_r       = 20

(* Vitesse de déplacement de base d'un Creet en pixels par tick d'animation. *)
let base_speed    = 2.0

(* Durée d'un tick d'animation en secondes, ciblant environ 60 images par seconde. *)
let tick_s        = 0.016

(* Intervalle en secondes entre chaque apparition automatique d'un nouveau Creet. *)
let spawn_s       = 5.0

(* Intervalle en secondes entre deux tirages de changement de direction aléatoire. *)
let dir_change_s  = 3.0

(* Probabilité de changer de direction à chaque tirage : en moyenne un virage toutes les 12 s. *)
let dir_change_prob = 0.25

(* Multiplicateur de vitesse appliqué aux Creets contaminés, les ralentissant de 15 %. *)
let sick_factor   = 0.85

(* Probabilité par contact et par tick qu'un Creet contagieux infecte un Creet Sain au toucher. *)
let contam_chance = 0.02

(* Probabilité qu'un Creet Malade devienne Berserk lors d'un contrôle d'évolution. *)
let berserk_prob  = 0.10

(* Probabilité qu'un Creet Malade devienne Mean lors d'un contrôle d'évolution. *)
let mean_prob     = 0.10

(* Intervalle en secondes entre les contrôles d'évolution d'un Creet Malade. *)
let evolve_s      = 10.0

(* Intervalle en secondes entre chaque étape de croissance d'un Creet Berserk. *)
let grow_s        = 10.0

(* Multiplicateur de rayon appliqué à chaque étape de croissance Berserk (augmentation de 10 %). *)
let grow_factor   = 1.10

(* Multiplicateur de taille maximum avant qu'un Creet Berserk meure : 4 fois le diamètre d'origine. *)
let max_size_mult = 4.0

(* Multiplicateur de rayon appliqué quand un Creet devient Mean (15 % plus petit). *)
let mean_shrink   = 0.85

(* Durée de vie d'un Creet Mean en secondes avant qu'il meure. *)
let mean_life_s   = 60.0

(* Accélération relative appliquée chaque seconde à tous les Creets (+0,3 % par seconde, composée). *)
let accel_per_sec = 0.003

(* Nombre de Creets présents au démarrage d'une nouvelle partie. *)
let init_count    = 7

(* ================================================================
   TYPES
   ================================================================ *)

(* Tous les états de santé possibles qu'un Creet peut avoir pendant la partie. *)
type health = Healthy | Sick | Berserk | Mean | Dead

(* État complet d'un Creet à un instant donné : position, direction, vitesse, taille et santé. *)
type creet = {
	id             : int;
	mutable x      : float;
	mutable y      : float;
	mutable dx     : float;
	mutable dy     : float;
	mutable speed  : float;
	mutable radius : float;
	mutable health : health;
	mutable dragged: bool;
}

(* Construit un Creet Sain de taille et de vitesse normales. *)
let make_creet ~id ~x ~y ~angle = {
	id; x; y;
	dx      = cos angle;
	dy      = sin angle;
	speed   = base_speed;
	radius  = float_of_int creet_r;
	health  = Healthy;
	dragged = false;
}

(* ================================================================
   PRÉDICATS D'ÉTAT
   ================================================================ *)

(* Vrai si le Creet porte le virus et peut le transmettre : Malade, Berserk ou Mean. *)
let is_contagious creet =
	match creet.health with
	| Sick | Berserk | Mean -> true
	| Healthy | Dead        -> false

(* Vrai si le joueur peut attraper ce Creet : les Berserk, les Mean et les morts sont intouchables. *)
let can_be_grabbed creet =
	match creet.health with
	| Healthy | Sick        -> true
	| Berserk | Mean | Dead -> false

(* ================================================================
   GÉOMÉTRIE
   ================================================================ *)

(* Distance euclidienne en pixels entre les centres de deux Creets. *)
let distance_between creet_a creet_b =
	let delta_x = creet_a.x -. creet_b.x and delta_y = creet_a.y -. creet_b.y in
	sqrt (delta_x *. delta_x +. delta_y *. delta_y)

(* Vrai si deux Creets se chevauchent physiquement : la distance entre leurs centres
   est strictement inférieure à la somme de leurs rayons. *)
let touching creet_a creet_b =
	distance_between creet_a creet_b < creet_a.radius +. creet_b.radius

(* Normalise un vecteur 2D à longueur unitaire ; retourne (1, 0) pour le vecteur nul. *)
let normalize vec_x vec_y =
	let vector_length = sqrt (vec_x *. vec_x +. vec_y *. vec_y) in
	if vector_length < 0.001 then (1.0, 0.0)
	else (vec_x /. vector_length, vec_y /. vector_length)

(* ================================================================
   DÉTECTION DE ZONE
   ================================================================ *)

(* Vrai si une partie du cercle du Creet touche la rivière toxique (ou se trouve au-dessus). *)
let in_river creet = creet.y -. creet.radius < float_of_int river_h

(* Vrai si le centre du Creet est posé dans le rectangle de l'hôpital, en bas de la zone de jeu. *)
let in_hospital creet =
	creet.x >= 0.0 && creet.x <= float_of_int area_w
	&& creet.y >= float_of_int (area_h - hospital_h) && creet.y <= float_of_int area_h

(* ================================================================
   DÉPLACEMENT
   ================================================================ *)

(* Rebond sur les bords : si le cercle dépasse un bord en s'en éloignant, la composante
   de direction correspondante est inversée (angle d'incidence = angle de réflexion).
   La position n'est jamais recalée : un Creet lâché hors de la zone y revient en ligne droite. *)
let bounce_edges creet =
	let arena_right = float_of_int area_w and arena_bottom = float_of_int area_h in
	if      creet.x -. creet.radius < 0.0          && creet.dx < 0.0 then creet.dx <- -. creet.dx
	else if creet.x +. creet.radius > arena_right  && creet.dx > 0.0 then creet.dx <- -. creet.dx;
	if      creet.y -. creet.radius < 0.0          && creet.dy < 0.0 then creet.dy <- -. creet.dy
	else if creet.y +. creet.radius > arena_bottom && creet.dy > 0.0 then creet.dy <- -. creet.dy

(* Déplacement en pixels pour ce tick : vitesse × accélération globale, réduite de 15 % si contaminé. *)
let effective_speed ~mult creet =
	let sick_slowdown = if is_contagious creet then sick_factor else 1.0 in
	creet.speed *. mult *. sick_slowdown

(* Déplace le Creet d'un tick dans sa direction courante, puis applique les rebonds. *)
let move_straight ~mult creet =
	let speed_val = effective_speed ~mult creet in
	creet.x <- creet.x +. creet.dx *. speed_val;
	creet.y <- creet.y +. creet.dy *. speed_val;
	bounce_edges creet

(* Retourne le Creet Sain le plus proche de [hunter], s'il en existe un. *)
let nearest_healthy creets hunter =
	List.fold_left (fun nearest_so_far other_creet ->
		if other_creet.health <> Healthy || other_creet == hunter then nearest_so_far
		else match nearest_so_far with
			| Some prev_closest
				when distance_between hunter prev_closest <= distance_between hunter other_creet ->
				nearest_so_far
			| _ -> Some other_creet
	) None creets

(* Oriente le Creet Mean vers le Creet Sain le plus proche puis le déplace d'un tick.
   Sans cible, il conserve sa direction courante. *)
let move_toward_nearest_healthy ~mult creets mean_creet =
	(match nearest_healthy creets mean_creet with
	| Some target ->
		let (dir_x, dir_y) = normalize (target.x -. mean_creet.x) (target.y -. mean_creet.y) in
		mean_creet.dx <- dir_x;
		mean_creet.dy <- dir_y
	| None -> ());
	move_straight ~mult mean_creet

(* Donne au Creet la direction de l'angle [angle] (en radians). *)
let set_direction creet angle =
	creet.dx <- cos angle;
	creet.dy <- sin angle

(* Vrai si le tirage [roll] ∈ [0, 1) déclenche un changement de direction. *)
let should_change_direction roll = roll < dir_change_prob

(* Position d'apparition à partir de deux tirages dans [0, 1) : toujours dans la bande
   centrale, hors de la rivière et hors de l'hôpital. *)
let spawn_position ~roll_x ~roll_y =
	let pad   = float_of_int (creet_r + 5) in
	let x_min = pad and x_max = float_of_int area_w -. pad in
	let y_min = float_of_int river_h +. pad and y_max = float_of_int (area_h - hospital_h) -. pad in
	(x_min +. roll_x *. (x_max -. x_min), y_min +. roll_y *. (y_max -. y_min))

(* Multiplicateur de vitesse global après une seconde supplémentaire de partie. *)
let next_speed_mult mult = mult *. (1.0 +. accel_per_sec)

(* ================================================================
   CONTAMINATION ET GUÉRISON
   ================================================================ *)

(* Passe un Creet Sain à l'état Malade. Retourne vrai si le Creet vient d'être contaminé. *)
let make_sick creet =
	if creet.health = Healthy then begin
		creet.health <- Sick;
		true
	end else false

(* Contamine le Creet s'il touche la rivière, sauf s'il est tenu par le joueur.
   Retourne vrai si le Creet vient d'être contaminé. *)
let river_contaminates creet =
	not creet.dragged && in_river creet && make_sick creet

(* Tente de contaminer chaque Creet Sain non tenu qui touche la source, avec la probabilité donnée.
   Seuls les Creets contagieux propagent le virus. Retourne la liste des Creets nouvellement contaminés. *)
let spread_from ~chance creets source_creet =
	if not (is_contagious source_creet) then []
	else List.filter (fun other_creet ->
		other_creet != source_creet
		&& other_creet.health = Healthy
		&& not other_creet.dragged
		&& touching source_creet other_creet
		&& Random.float 1.0 < chance
		&& make_sick other_creet
	) creets

(* Guérit un Creet Malade lâché par le joueur dans l'hôpital : il redevient Sain,
   retrouve sa couleur et sa vitesse normale. Les Berserk et Mean ne sont jamais guéris.
   Retourne vrai si le Creet a été guéri. *)
let heal_on_drop creet =
	if creet.health = Sick && in_hospital creet then begin
		creet.health <- Healthy;
		creet.speed  <- base_speed;
		true
	end else false

(* ================================================================
   ÉVOLUTION : BERSERK ET MEAN
   ================================================================ *)

(* Résultat d'un contrôle d'évolution, tiré à partir d'un nombre [roll] ∈ [0, 1) :
   10 % Berserk, 10 % Mean, 80 % reste Malade. Les deux mutations sont exclusives. *)
let evolution_of_roll roll =
	if roll < berserk_prob then Berserk
	else if roll < berserk_prob +. mean_prob then Mean
	else Sick

(* Applique un contrôle d'évolution à un Creet Malade et retourne son nouvel état.
   Un Creet qui devient Mean rétrécit à 85 % de sa taille. Sans effet sur les autres états. *)
let evolve ~roll creet =
	if creet.health = Sick then begin
		match evolution_of_roll roll with
		| Berserk -> creet.health <- Berserk
		| Mean    -> creet.health <- Mean; creet.radius <- creet.radius *. mean_shrink
		| _       -> ()
	end;
	creet.health

(* Fait grossir un Creet Berserk de 10 % de diamètre. *)
let berserk_grow creet =
	creet.radius <- creet.radius *. grow_factor

(* Vrai si le diamètre d'un Creet Berserk a atteint 4 fois sa taille d'origine, déclenchant sa mort. *)
let berserk_should_die creet =
	creet.radius *. 2.0 >= float_of_int (creet_r * 2) *. max_size_mult

(* ================================================================
   ÉTAT DE LA PARTIE
   ================================================================ *)

(* Vrai si la partie est perdue : il ne reste plus aucun Creet Sain
   (tous les Creets sont morts ou contaminés). *)
let game_is_over creets =
	not (List.exists (fun creet -> creet.health = Healthy) creets)

(* ================================================================
   AFFICHAGE
   ================================================================ *)

(* Classe CSS correspondant à un état de santé ; chaque état a sa propre couleur dans la feuille de style. *)
let health_class = function
	| Healthy -> "healthy"
	| Sick    -> "sick"
	| Berserk -> "berserk"
	| Mean    -> "mean"
	| Dead    -> "dead"
