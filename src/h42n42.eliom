(* H42N42 — application Eliom.
   Le serveur génère la page HTML avec TyXML (Eliom_content.Html.D), ce qui la valide
   statiquement à la compilation. Toute la simulation tourne côté client, dans la
   section [%%client], compilée en JavaScript par js_of_ocaml. *)

[%%shared
open Eliom_content.Html.D
]

module H42n42_app = Eliom_registration.App (struct
	let application_name = "h42n42"
	let global_data_path = None
end)

let main_service =
	Eliom_service.create
		~path:(Eliom_service.Path [])
		~meth:(Eliom_service.Get Eliom_parameter.unit)
		()

(* ================================================================
   CLIENT : ÉTAT DU JEU
   ================================================================ *)

[%%client
open Js_of_ocaml
open Js_of_ocaml_lwt
module Manip = Eliom_content.Html.Manip
module To_dom = Eliom_content.Html.To_dom

(* Un Creet tel que vu par le client : son état logique et son élément du DOM. *)
type game_creet = {
	lc                : Logic.creet;
	elt               : Html_types.div elt;
	dom               : Dom_html.divElement Js.t;
	mutable infection : int;                     (* numéro de la contamination en cours *)
	mutable release   : unit Lwt.u option;       (* force la fin du glisser-déposer en cours *)
}

(* État global d'une partie. *)
type game = {
	area               : Html_types.div elt;
	area_dom           : Dom_html.divElement Js.t;
	overlay            : Html_types.div elt;
	stats              : Html_types.span elt;
	final_time         : Html_types.span elt;
	mutable creets     : game_creet list;
	mutable next_id    : int;
	mutable speed_mult : float;
	mutable elapsed    : int;
	mutable over       : bool;
}

(* ================================================================
   CLIENT : RENDU
   ================================================================ *)

let px v = Js.string (Printf.sprintf "%.1fpx" v)

(* Recopie la position et la taille logiques du Creet dans le style de son élément. *)
let render gc =
	let style = gc.dom##.style and d = gc.lc.Logic.radius *. 2.0 in
	style##.width  := px d;
	style##.height := px d;
	style##.left   := px (gc.lc.Logic.x -. gc.lc.Logic.radius);
	style##.top    := px (gc.lc.Logic.y -. gc.lc.Logic.radius)

(* Remplace la classe d'état de santé de l'élément par celle de l'état courant. *)
let render_health gc =
	Manip.Class.removes gc.elt (List.map Logic.health_class Logic.[Healthy; Sick; Berserk; Mean; Dead]);
	Manip.Class.add gc.elt (Logic.health_class gc.lc.Logic.health)

(* Joue une animation CSS ponctuelle (contamination, guérison, apparition) sur le Creet. *)
let flash gc cls =
	Manip.Class.remove gc.elt cls;
	ignore gc.dom##.offsetWidth; (* force un reflow pour relancer l'animation *)
	Manip.Class.add gc.elt cls;
	Lwt.async (fun () ->
		let%lwt () = Lwt_js.sleep 0.8 in
		Manip.Class.remove gc.elt cls;
		Lwt.return_unit)

let format_time seconds = Printf.sprintf "%d:%02d" (seconds / 60) (seconds mod 60)

(* Met à jour la ligne de statistiques sous la zone de jeu. *)
let render_stats g =
	let count h = List.length (List.filter (fun gc -> gc.lc.Logic.health = h) g.creets) in
	Manip.replaceChildren g.stats [txt (Printf.sprintf
		"Healthy %d · Sick %d · Berserk %d · Mean %d · Time %s · Speed ×%.2f"
		(count Logic.Healthy) (count Logic.Sick) (count Logic.Berserk) (count Logic.Mean)
		(format_time g.elapsed) g.speed_mult)]

(* ================================================================
   CLIENT : CYCLE DE VIE D'UN CREET
   ================================================================ *)

let rand_angle () = Random.float (2.0 *. Float.pi)

(* Termine le glisser-déposer en cours sur ce Creet, s'il y en a un. *)
let release_drag gc =
	match gc.release with
	| Some wakener -> gc.release <- None; Lwt.wakeup_later wakener ()
	| None         -> ()

(* Retire définitivement un Creet de la partie et de la page. *)
let kill g gc =
	release_drag gc;
	gc.lc.Logic.health <- Logic.Dead;
	Manip.removeSelf gc.elt;
	g.creets <- List.filter (fun other -> other != gc) g.creets

(* Mean : meurt exactement une minute après sa transformation. *)
let mean_loop g gc =
	let%lwt () = Lwt_js.sleep Logic.mean_life_s in
	if not g.over && gc.lc.Logic.health = Logic.Mean then kill g gc;
	Lwt.return_unit

(* Berserk : grossit de 10 % toutes les 10 secondes et meurt à 4 fois son diamètre d'origine. *)
let rec berserk_loop g gc =
	let%lwt () = Lwt_js.sleep Logic.grow_s in
	if g.over || gc.lc.Logic.health <> Logic.Berserk then Lwt.return_unit
	else begin
		Logic.berserk_grow gc.lc;
		if Logic.berserk_should_die gc.lc then (kill g gc; Lwt.return_unit)
		else (render gc; berserk_loop g gc)
	end

(* Contrôle d'évolution toutes les 10 secondes tant que le Creet reste malade.
   [infection] identifie la contamination qui a lancé la boucle : si le Creet a été
   guéri puis recontaminé entre-temps, cette ancienne boucle s'arrête. *)
let rec evolve_loop g gc infection =
	let%lwt () = Lwt_js.sleep Logic.evolve_s in
	if g.over || gc.infection <> infection || gc.lc.Logic.health <> Logic.Sick then Lwt.return_unit
	else match Logic.evolve ~roll:(Random.float 1.0) gc.lc with
		| Logic.Berserk ->
			release_drag gc; render_health gc; render gc; flash gc "mutated";
			berserk_loop g gc
		| Logic.Mean ->
			release_drag gc; render_health gc; render gc; flash gc "mutated";
			mean_loop g gc
		| _ -> evolve_loop g gc infection

(* À appeler quand un Creet vient d'être contaminé : couleur, animation et contrôles d'évolution. *)
let on_infected g gc =
	gc.infection <- gc.infection + 1;
	render_health gc;
	flash gc "infected";
	let infection = gc.infection in
	Lwt.async (fun () -> evolve_loop g gc infection)

(* Thread principal d'un Creet : un pas de déplacement, la rivière et la contagion à chaque tick. *)
let rec creet_loop g gc =
	if g.over || gc.lc.Logic.health = Logic.Dead then Lwt.return_unit
	else begin
		if not gc.lc.Logic.dragged then begin
			(match gc.lc.Logic.health with
			| Logic.Mean ->
				Logic.move_toward_nearest_healthy ~mult:g.speed_mult
					(List.map (fun other -> other.lc) g.creets) gc.lc
			| _ -> Logic.move_straight ~mult:g.speed_mult gc.lc);
			if Logic.river_contaminates gc.lc then on_infected g gc;
			let infected =
				Logic.spread_from ~chance:Logic.contam_chance (List.map (fun other -> other.lc) g.creets) gc.lc in
			if infected <> [] then
				List.iter (fun other -> if List.memq other.lc infected then on_infected g other) g.creets;
			render gc
		end;
		let%lwt () = Lwt_js.sleep Logic.tick_s in
		creet_loop g gc
	end

(* Changements de direction aléatoires, peu fréquents pour que les trajectoires restent lisibles. *)
let rec direction_loop g gc =
	let%lwt () = Lwt_js.sleep Logic.dir_change_s in
	if g.over || gc.lc.Logic.health = Logic.Dead then Lwt.return_unit
	else begin
		if not gc.lc.Logic.dragged && gc.lc.Logic.health <> Logic.Mean
			&& Logic.should_change_direction (Random.float 1.0)
		then Logic.set_direction gc.lc (rand_angle ());
		direction_loop g gc
	end

(* ================================================================
   CLIENT : GLISSER-DÉPOSER
   ================================================================ *)

(* Position du pointeur dans le repère de la zone de jeu (bordure exclue). *)
let pointer_in_area g (ev : Dom_html.mouseEvent Js.t) =
	let rect = g.area_dom##getBoundingClientRect in
	(float_of_int ev##.clientX -. rect##.left -. float_of_int g.area_dom##.clientLeft,
	 float_of_int ev##.clientY -. rect##.top  -. float_of_int g.area_dom##.clientTop)

(* Le joueur saisit le Creet à la souris et le déplace n'importe où, même hors de la zone.
   Pendant le glisser-déposer le Creet est immobile, invulnérable et mis en évidence.
   Lâché dans l'hôpital, un Creet Malade est guéri. *)
let setup_drag g gc =
	Lwt.async (fun () ->
		Lwt_js_events.mousedowns gc.dom (fun ev _ ->
			if g.over || not (Logic.can_be_grabbed gc.lc) then Lwt.return_unit
			else begin
				Dom.preventDefault ev;
				let (px0, py0) = pointer_in_area g ev in
				let grab_dx = gc.lc.Logic.x -. px0 and grab_dy = gc.lc.Logic.y -. py0 in
				let (released, wakener) = Lwt.wait () in
				gc.release <- Some wakener;
				gc.lc.Logic.dragged <- true;
				Manip.Class.add gc.elt "dragged";
				let rec follow () =
					let%lwt mv = Lwt_js_events.mousemove Dom_html.document in
					let (pointer_x, pointer_y) = pointer_in_area g mv in
					gc.lc.Logic.x <- pointer_x +. grab_dx;
					gc.lc.Logic.y <- pointer_y +. grab_dy;
					render gc;
					follow ()
				in
				let%lwt () = Lwt.pick [
					follow ();
					Lwt.map ignore (Lwt_js_events.mouseup Dom_html.document);
					released;
				] in
				gc.release <- None;
				gc.lc.Logic.dragged <- false;
				Manip.Class.remove gc.elt "dragged";
				if Logic.heal_on_drop gc.lc then begin
					render_health gc;
					flash gc "healed"
				end;
				Logic.set_direction gc.lc (rand_angle ());
				render gc;
				Lwt.return_unit
			end))

(* ================================================================
   CLIENT : PARTIE
   ================================================================ *)

(* Crée un nouveau Creet Sain dans la bande centrale et lance ses threads. *)
let spawn_creet g =
	let (x, y) = Logic.spawn_position ~roll_x:(Random.float 1.0) ~roll_y:(Random.float 1.0) in
	let lc = Logic.make_creet ~id:g.next_id ~x ~y ~angle:(rand_angle ()) in
	g.next_id <- g.next_id + 1;
	let elt = div ~a:[a_class ["creet"; Logic.health_class lc.Logic.health]] [] in
	let gc = { lc; elt; dom = To_dom.of_div elt; infection = 0; release = None } in
	Manip.appendChild g.area elt;
	render gc;
	flash gc "spawned";
	g.creets <- gc :: g.creets;
	setup_drag g gc;
	Lwt.async (fun () -> creet_loop g gc);
	Lwt.async (fun () -> direction_loop g gc)

(* Tant qu'il reste au moins un Creet Sain, un nouveau Creet naît périodiquement. *)
let rec spawn_loop g =
	let%lwt () = Lwt_js.sleep Logic.spawn_s in
	if g.over then Lwt.return_unit
	else begin
		if List.exists (fun gc -> gc.lc.Logic.health = Logic.Healthy) g.creets then spawn_creet g;
		spawn_loop g
	end

(* Chaque seconde : accélération globale de tous les Creets et chronomètre. *)
let rec clock_loop g =
	let%lwt () = Lwt_js.sleep 1.0 in
	if g.over then Lwt.return_unit
	else begin
		g.speed_mult <- Logic.next_speed_mult g.speed_mult;
		g.elapsed <- g.elapsed + 1;
		clock_loop g
	end

(* Surveille la fin de partie : dès qu'il n'y a plus aucun Creet Sain, tout s'arrête
   et le message GAME OVER s'affiche. *)
let rec game_over_loop g =
	render_stats g;
	if Logic.game_is_over (List.map (fun gc -> gc.lc) g.creets) then begin
		g.over <- true;
		List.iter release_drag g.creets;
		Manip.replaceChildren g.final_time [txt (format_time g.elapsed)];
		Manip.Class.add g.overlay "visible";
		Lwt.return_unit
	end else
		let%lwt () = Lwt_js.sleep 0.1 in
		game_over_loop g

(* Point d'entrée côté client, appelé au chargement de la page. *)
let start ~area ~overlay ~stats ~final_time ~restart =
	Random.self_init ();
	let g = {
		area; area_dom = To_dom.of_div area; overlay; stats; final_time;
		creets = []; next_id = 0; speed_mult = 1.0; elapsed = 0; over = false;
	} in
	for _ = 1 to Logic.init_count do spawn_creet g done;
	Lwt.async (fun () -> spawn_loop g);
	Lwt.async (fun () -> clock_loop g);
	Lwt.async (fun () -> game_over_loop g);
	Lwt.async (fun () ->
		Lwt_js_events.clicks (To_dom.of_button restart) (fun _ _ ->
			Dom_html.window##.location##reload;
			Lwt.return_unit))
]

(* ================================================================
   SERVEUR : PAGE
   ================================================================ *)

let px_style props =
	String.concat ";" (List.map (fun (prop, value) -> Printf.sprintf "%s:%dpx" prop value) props)

(* Pastille colorée et libellé de la légende. *)
let legend_item cls label =
	div ~a:[a_class ["legend-item"]] [
		span ~a:[a_class ["legend-dot"; cls]] [];
		span [txt label];
	]

let page () =
	let river = div ~a:[a_class ["river"]; a_style (px_style ["height", Logic.river_h])]
		[txt "☣ TOXIC RIVER"] in
	let hospital = div ~a:[a_class ["hospital"]; a_style (px_style ["height", Logic.hospital_h])]
		[txt "✚ HOSPITAL — drop sick Creets here to heal them"] in
	let final_time = span [txt "0:00"] in
	let restart = button ~a:[a_class ["restart"]] [txt "Play again"] in
	let overlay = div ~a:[a_class ["game-over"]] [
		span ~a:[a_class ["game-over-text"]] [txt "GAME OVER"];
		p ~a:[a_class ["game-over-info"]] [txt "No healthy Creet left. You held on for "; final_time; txt "."];
		restart;
	] in
	let area = div
		~a:[a_class ["game-area"];
		    a_style (px_style ["width", Logic.area_w; "height", Logic.area_h])]
		[river; hospital; overlay] in
	let stats = span ~a:[a_class ["stats"]] [] in
	let _ = [%client (start ~area:~%area ~overlay:~%overlay ~stats:~%stats
		~final_time:~%final_time ~restart:~%restart : unit)] in
	let favicon = link ~rel:[`Icon] ~a:[a_mime_type "image/svg+xml"]
		~href:(make_uri ~service:(Eliom_service.static_dir ()) ["favicon.svg"]) () in
	Eliom_tools.D.html ~title:"H42N42" ~css:[["css"; "style.css"]] ~other_head:[favicon]
		(body [
			h1 [txt "H42N42"];
			p ~a:[a_class ["subtitle"]]
				[txt "Keep the Creets away from the river and drag the sick ones to the hospital!"];
			area;
			p ~a:[a_class ["status"]] [stats];
			div ~a:[a_class ["legend"]] [
				legend_item "healthy" "Healthy";
				legend_item "sick"    "Sick (drag to hospital)";
				legend_item "berserk" "Berserk (grows, untouchable)";
				legend_item "mean"    "Mean (hunts healthy Creets, untouchable)";
			];
		])

let () =
	H42n42_app.register ~service:main_service (fun () () -> Lwt.return (page ()))
