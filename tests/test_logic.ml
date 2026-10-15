(* Tests unitaires du module Logic (logique pure du jeu), exécutés en natif avec Alcotest.
   Chaque groupe correspond à une règle du sujet ; la partie DOM / Lwt est couverte
   par les tests navigateur de tests/e2e. *)

open Logic

(* ================================================================
   UTILITAIRES
   ================================================================ *)

(* Construit un Creet avec des valeurs par défaut, surchargées par les paramètres nommés fournis. *)
let make_creet ?(id=0) ?(x=200.) ?(y=200.) ?(dx=1.) ?(dy=0.)
               ?(speed=base_speed) ?(radius=float_of_int creet_r)
               ?(health=Healthy) ?(dragged=false) () : creet =
  { id; x; y; dx; dy; speed; radius; health; dragged }

(* Égalité de flottants à epsilon près (par défaut 1e-9). *)
let float_approx_eq ?(eps=1e-9) value_a value_b = abs_float (value_a -. value_b) < eps

(* Vérifie qu'une condition booléenne est vraie, avec un message en cas d'échec. *)
let check msg condition = Alcotest.(check bool) msg true condition

(* Norme du vecteur de direction d'un Creet. *)
let direction_norm creet = sqrt (creet.dx *. creet.dx +. creet.dy *. creet.dy)

let all_states = [Healthy; Sick; Berserk; Mean; Dead]

(* ================================================================
   CRÉATION D'UN CREET
   ================================================================ *)

let test_make_creet_defaults () =
  let creet = Logic.make_creet ~id:7 ~x:100. ~y:150. ~angle:0. in
  check "id"           (creet.id = 7);
  check "position"     (creet.x = 100. && creet.y = 150.);
  check "Sain"         (creet.health = Healthy);
  check "non tenu"     (not creet.dragged);
  check "vitesse base" (float_approx_eq creet.speed base_speed);
  check "rayon base"   (float_approx_eq creet.radius (float_of_int creet_r))

let test_make_creet_direction_unit () =
  List.iter (fun angle ->
    let creet = Logic.make_creet ~id:0 ~x:0. ~y:0. ~angle in
    check "direction unitaire" (float_approx_eq (direction_norm creet) 1.0)
  ) [0.; 0.7; 1.5; 3.14; 4.2; 6.0]

let test_make_creet_angle () =
  let creet = Logic.make_creet ~id:0 ~x:0. ~y:0. ~angle:(Float.pi /. 2.) in
  check "angle π/2 : vers le bas" (float_approx_eq creet.dx 0.0 && float_approx_eq creet.dy 1.0)

let test_set_direction () =
  let creet = make_creet () in
  set_direction creet Float.pi;
  check "angle π : vers la gauche" (float_approx_eq creet.dx (-1.0) && float_approx_eq ~eps:1e-6 creet.dy 0.0)

(* ================================================================
   PRÉDICATS D'ÉTAT
   ================================================================ *)

let test_contagious_states () =
  check "Sain non contagieux"  (not (is_contagious (make_creet ~health:Healthy ())));
  check "Malade contagieux"    (is_contagious (make_creet ~health:Sick ()));
  check "Berserk contagieux"   (is_contagious (make_creet ~health:Berserk ()));
  check "Mean contagieux"      (is_contagious (make_creet ~health:Mean ()));
  check "Mort non contagieux"  (not (is_contagious (make_creet ~health:Dead ())))

let test_grab_states () =
  check "Sain saisissable"        (can_be_grabbed (make_creet ~health:Healthy ()));
  check "Malade saisissable"      (can_be_grabbed (make_creet ~health:Sick ()));
  check "Berserk non saisissable" (not (can_be_grabbed (make_creet ~health:Berserk ())));
  check "Mean non saisissable"    (not (can_be_grabbed (make_creet ~health:Mean ())));
  check "Mort non saisissable"    (not (can_be_grabbed (make_creet ~health:Dead ())))

(* ================================================================
   GÉOMÉTRIE — distance_between
   ================================================================ *)

let test_dist_same_point () =
  let creet = make_creet ~x:0. ~y:0. () in
  check "même point = 0" (float_approx_eq (distance_between creet creet) 0.0)

let test_dist_345_triangle () =
  let creet_a = make_creet ~x:0. ~y:0. () and creet_b = make_creet ~x:3. ~y:4. () in
  check "triangle 3-4-5" (float_approx_eq (distance_between creet_a creet_b) 5.0)

let test_dist_symmetric () =
  let creet_a = make_creet ~x:10. ~y:20. () and creet_b = make_creet ~x:50. ~y:80. () in
  check "symétrique" (float_approx_eq (distance_between creet_a creet_b) (distance_between creet_b creet_a))

let test_dist_negative_coords () =
  let creet_a = make_creet ~x:(-3.) ~y:0. () and creet_b = make_creet ~x:0. ~y:4. () in
  check "coordonnées négatives (hors zone)" (float_approx_eq (distance_between creet_a creet_b) 5.0)

let test_dist_max_arena () =
  let creet_a = make_creet ~x:0. ~y:0. () and creet_b = make_creet ~x:900. ~y:600. () in
  check "diagonale de la zone" (float_approx_eq (distance_between creet_a creet_b) (sqrt (900.*.900. +. 600.*.600.)))

let test_dist_triangle_inequality () =
  let creet_a = make_creet ~x:0.   ~y:0.   () in
  let creet_b = make_creet ~x:100. ~y:0.   () in
  let creet_c = make_creet ~x:50.  ~y:100. () in
  check "inégalité triangulaire"
    (distance_between creet_a creet_c <= distance_between creet_a creet_b +. distance_between creet_b creet_c +. 1e-9)

(* ================================================================
   GÉOMÉTRIE — touching (contact précis : somme des rayons)
   ================================================================ *)

let test_touching_exact_boundary () =
  (* distance = r1 + r2 = 40 : les cercles se touchent tout juste, pas de chevauchement *)
  let creet_a = make_creet ~x:0. ~radius:20. () and creet_b = make_creet ~x:40. ~radius:20. () in
  check "distance = somme des rayons : pas de contact" (not (touching creet_a creet_b))

let test_touching_overlap () =
  let creet_a = make_creet ~x:0. ~radius:20. () and creet_b = make_creet ~x:39.99 ~radius:20. () in
  check "chevauchement d'un centième de pixel : contact" (touching creet_a creet_b)

let test_touching_far_apart () =
  let creet_a = make_creet ~x:0. ~radius:20. () and creet_b = make_creet ~x:200. ~radius:20. () in
  check "éloignés : pas de contact" (not (touching creet_a creet_b))

let test_touching_diagonal () =
  (* distance = 50, rayons 20 + 20 = 40 : sur une diagonale, pas de contact même si |dx|,|dy| < 40 *)
  let creet_a = make_creet ~x:0. ~y:0. ~radius:20. () and creet_b = make_creet ~x:30. ~y:40. ~radius:20. () in
  check "diagonale : boîtes englobantes chevauchées mais cercles disjoints" (not (touching creet_a creet_b))

let test_touching_different_radii () =
  let small = make_creet ~x:0. ~radius:5. () in
  check "rayons 5 + 20, distance 24 : contact"    (touching small (make_creet ~x:24. ~radius:20. ()));
  check "rayons 5 + 20, distance 26 : pas contact" (not (touching small (make_creet ~x:26. ~radius:20. ())))

let test_touching_berserk_large_radius () =
  let berserk_creet = make_creet ~x:0. ~radius:80. () and far_creet = make_creet ~x:99. ~radius:20. () in
  check "Berserk de rayon 80 touche à 99 px" (touching berserk_creet far_creet)

let test_touching_mean_small_radius () =
  let mean_creet = make_creet ~x:0. ~radius:(20. *. mean_shrink) () in
  check "Mean rétréci : 37 px trop loin" (not (touching mean_creet (make_creet ~x:37. ~radius:20. ())))

let test_touching_symmetric () =
  let creet_a = make_creet ~x:0. ~radius:20. () in
  List.iter (fun distance ->
    let creet_b = make_creet ~x:distance ~radius:20. () in
    check "touching symétrique" (touching creet_a creet_b = touching creet_b creet_a)
  ) [10.; 35.; 40.; 50.]

(* ================================================================
   GÉOMÉTRIE — normalize
   ================================================================ *)

let test_normalize_345 () =
  let (norm_x, norm_y) = normalize 3.0 4.0 in
  check "3-4-5" (float_approx_eq norm_x 0.6 && float_approx_eq norm_y 0.8)

let test_normalize_zero_vector () =
  let (norm_x, norm_y) = normalize 0.0 0.0 in
  check "vecteur nul → (1, 0)" (float_approx_eq norm_x 1.0 && float_approx_eq norm_y 0.0)

let test_normalize_unit_length () =
  List.iter (fun (vec_x, vec_y) ->
    let (norm_x, norm_y) = normalize vec_x vec_y in
    check "longueur 1" (float_approx_eq (sqrt (norm_x *. norm_x +. norm_y *. norm_y)) 1.0)
  ) [(5., 3.); (-1., 0.); (0., -7.); (300., 400.); (-2., -2.); (0.01, 0.)]

let test_normalize_idempotent () =
  let (norm_x1, norm_y1) = normalize 3.0 4.0 in
  let (norm_x2, norm_y2) = normalize norm_x1 norm_y1 in
  check "idempotent" (float_approx_eq norm_x1 norm_x2 && float_approx_eq norm_y1 norm_y2)

(* ================================================================
   ZONES — in_river (river_h = 60)
   ================================================================ *)

let test_river_center_deep_in () =
  check "centre dans la rivière" (in_river (make_creet ~y:30. ~radius:20. ()))

let test_river_edge_touching () =
  (* bord supérieur = 79 - 20 = 59 < 60 : le cercle touche la rivière *)
  check "bord du cercle dans la rivière" (in_river (make_creet ~y:79. ~radius:20. ()))

let test_river_exactly_on_boundary () =
  check "cercle tangent à la rivière : hors rivière" (not (in_river (make_creet ~y:80. ~radius:20. ())))

let test_river_safe_zone () =
  check "milieu de la zone : hors rivière" (not (in_river (make_creet ~y:300. ())))

let test_river_above_area () =
  (* Un Creet lâché au-dessus de la zone de jeu est forcément dans la rivière. *)
  check "au-dessus de la zone : rivière" (in_river (make_creet ~y:(-50.) ()))

let test_river_grown_berserk () =
  check "Berserk de rayon 50 centré à y = 105 touche la rivière" (in_river (make_creet ~y:105. ~radius:50. ()))

(* ================================================================
   ZONES — in_hospital (rectangle x ∈ [0, 900], y ∈ [520, 600])
   ================================================================ *)

let test_hospital_center_in () =
  check "centre dans l'hôpital" (in_hospital (make_creet ~x:450. ~y:560. ()))

let test_hospital_top_boundary () =
  check "centre sur la limite haute (520) : dans l'hôpital" (in_hospital (make_creet ~y:520. ()));
  check "centre juste au-dessus (519.9) : hors hôpital"     (not (in_hospital (make_creet ~y:519.9 ())))

let test_hospital_only_edge_overlapping () =
  (* Le cercle déborde sur l'hôpital mais le Creet n'y a pas été déposé. *)
  check "seul le bord du cercle déborde : hors hôpital" (not (in_hospital (make_creet ~y:510. ())))

let test_hospital_bottom_boundary () =
  check "centre sur le bord bas (600) : dans l'hôpital" (in_hospital (make_creet ~y:600. ()));
  check "centre sous la zone (601) : hors hôpital"     (not (in_hospital (make_creet ~y:601. ())))

let test_hospital_horizontal_limits () =
  check "x = 0 : dans l'hôpital"         (in_hospital (make_creet ~x:0. ~y:560. ()));
  check "x = 900 : dans l'hôpital"       (in_hospital (make_creet ~x:900. ~y:560. ()));
  check "x = -1 (hors zone) : non"       (not (in_hospital (make_creet ~x:(-1.) ~y:560. ())));
  check "x = 901 (hors zone) : non"      (not (in_hospital (make_creet ~x:901. ~y:560. ())))

let test_hospital_safe_zone () =
  check "milieu de la zone : hors hôpital" (not (in_hospital (make_creet ~y:300. ())))

(* ================================================================
   DÉPLACEMENT — bounce_edges (angle d'incidence = angle de réflexion)
   ================================================================ *)

let test_bounce_left_wall () =
  let creet = make_creet ~x:5. ~y:300. ~dx:(-0.6) ~dy:0.8 () in
  bounce_edges creet;
  check "mur gauche : dx inversé" (float_approx_eq creet.dx 0.6);
  check "mur gauche : dy conservé" (float_approx_eq creet.dy 0.8)

let test_bounce_right_wall () =
  let creet = make_creet ~x:895. ~y:300. ~dx:0.6 ~dy:(-0.8) () in
  bounce_edges creet;
  check "mur droit : dx inversé" (float_approx_eq creet.dx (-0.6));
  check "mur droit : dy conservé" (float_approx_eq creet.dy (-0.8))

let test_bounce_top_wall () =
  let creet = make_creet ~x:300. ~y:5. ~dx:0.6 ~dy:(-0.8) () in
  bounce_edges creet;
  check "mur haut : dy inversé"  (float_approx_eq creet.dy 0.8);
  check "mur haut : dx conservé" (float_approx_eq creet.dx 0.6)

let test_bounce_bottom_wall () =
  let creet = make_creet ~x:300. ~y:595. ~dx:0.6 ~dy:0.8 () in
  bounce_edges creet;
  check "mur bas : dy inversé"  (float_approx_eq creet.dy (-0.8));
  check "mur bas : dx conservé" (float_approx_eq creet.dx 0.6)

let test_bounce_corner () =
  let creet = make_creet ~x:5. ~y:5. ~dx:(-0.6) ~dy:(-0.8) () in
  bounce_edges creet;
  check "coin : les deux composantes inversées" (float_approx_eq creet.dx 0.6 && float_approx_eq creet.dy 0.8)

let test_bounce_preserves_norm () =
  List.iter (fun (x, y, dx, dy) ->
    let creet = make_creet ~x ~y ~dx ~dy () in
    bounce_edges creet;
    check "norme de la direction conservée" (float_approx_eq (direction_norm creet) 1.0)
  ) [(5., 300., -0.6, 0.8); (895., 300., 0.6, 0.8); (300., 5., 0.8, -0.6); (300., 595., -0.8, 0.6); (5., 595., -0.6, 0.8)]

let test_bounce_angle_reflection () =
  (* Angle d'incidence 30° sur le mur droit : l'angle de réflexion par rapport à la normale vaut aussi 30°. *)
  let angle_in = Float.pi /. 6. in
  let creet = make_creet ~x:895. ~y:300. ~dx:(cos angle_in) ~dy:(sin angle_in) () in
  bounce_edges creet;
  let angle_out = atan2 creet.dy (-. creet.dx) in
  check "réflexion à 30°" (float_approx_eq angle_out angle_in)

let test_no_bounce_in_play_zone () =
  let creet = make_creet ~x:300. ~y:300. ~dx:0.6 ~dy:0.8 () in
  bounce_edges creet;
  check "zone de jeu : direction inchangée" (float_approx_eq creet.dx 0.6 && float_approx_eq creet.dy 0.8)

let test_bounce_moving_inward_unchanged () =
  (* Déjà en train de revenir dans la zone : pas de second rebond qui le renverrait dehors. *)
  let creet = make_creet ~x:5. ~y:300. ~dx:0.6 ~dy:0.8 () in
  bounce_edges creet;
  check "revient vers l'intérieur : dx inchangé" (float_approx_eq creet.dx 0.6)

let test_bounce_never_teleports () =
  let creet = make_creet ~x:(-300.) ~y:(-200.) ~dx:(-0.6) ~dy:(-0.8) () in
  bounce_edges creet;
  check "hors zone : position conservée" (creet.x = -300. && creet.y = -200.);
  check "hors zone : repart vers la zone" (creet.dx > 0. && creet.dy > 0.)

let test_bounce_exactly_tangent () =
  let creet = make_creet ~x:(float_of_int creet_r) ~y:300. ~dx:(-1.) ~dy:0. () in
  bounce_edges creet;
  check "tangent au mur gauche : pas encore de rebond" (float_approx_eq creet.dx (-1.))

(* ================================================================
   DÉPLACEMENT — effective_speed (Malade : 15 % plus lent)
   ================================================================ *)

let test_speed_healthy () =
  check "Sain mult 1" (float_approx_eq (effective_speed ~mult:1.0 (make_creet ~speed:2.0 ())) 2.0);
  check "Sain mult 2" (float_approx_eq (effective_speed ~mult:2.0 (make_creet ~speed:2.0 ())) 4.0)

let test_speed_sick_15pct_slower () =
  let healthy_speed = effective_speed ~mult:1.0 (make_creet ~health:Healthy ()) in
  let sick_speed    = effective_speed ~mult:1.0 (make_creet ~health:Sick ()) in
  check "Malade = 85 % de la vitesse d'un Sain" (float_approx_eq (sick_speed /. healthy_speed) 0.85)

let test_speed_all_contaminated_slower () =
  List.iter (fun health ->
    check "contaminé : 15 % plus lent"
      (float_approx_eq (effective_speed ~mult:1.0 (make_creet ~health ())) (base_speed *. 0.85))
  ) [Sick; Berserk; Mean]

let test_speed_scales_with_mult () =
  let creet = make_creet ~health:Sick () in
  check "linéaire en mult" (float_approx_eq (effective_speed ~mult:3.0 creet) (3.0 *. effective_speed ~mult:1.0 creet))

let test_speed_zero () =
  check "mult = 0 : immobile" (float_approx_eq (effective_speed ~mult:0.0 (make_creet ())) 0.0)

(* ================================================================
   DÉPLACEMENT — move_straight
   ================================================================ *)

let test_move_straight_right () =
  let creet = make_creet ~x:100. ~y:200. ~dx:1. ~dy:0. ~speed:2.0 () in
  move_straight ~mult:1.0 creet;
  check "x avance de 2" (float_approx_eq creet.x 102.);
  check "y inchangé"    (float_approx_eq creet.y 200.)

let test_move_straight_sick_slower () =
  let creet = make_creet ~x:100. ~dx:1. ~dy:0. ~speed:2.0 ~health:Sick () in
  move_straight ~mult:1.0 creet;
  check "Malade avance de 1.7" (float_approx_eq creet.x 101.7)

let test_move_straight_constant_speed () =
  (* Ligne droite à vitesse constante : après n ticks, le déplacement vaut n × vitesse. *)
  let creet = make_creet ~x:100. ~y:300. ~dx:0.6 ~dy:0.8 ~speed:2.0 () in
  for _ = 1 to 50 do move_straight ~mult:1.0 creet done;
  check "x après 50 ticks" (float_approx_eq ~eps:1e-6 creet.x (100. +. 50. *. 2. *. 0.6));
  check "y après 50 ticks" (float_approx_eq ~eps:1e-6 creet.y (300. +. 50. *. 2. *. 0.8))

let test_move_straight_bounces () =
  let creet = make_creet ~x:875. ~y:300. ~dx:1. ~dy:0. ~speed:10.0 () in
  move_straight ~mult:1.0 creet;
  check "touche le mur droit : repart vers la gauche" (creet.dx < 0.)

let test_move_stays_in_area_long_run () =
  (* 20 000 ticks de rebonds : le Creet ne dépasse jamais le bord de plus d'un pas. *)
  let creet = make_creet ~x:450. ~y:300. ~dx:0.6 ~dy:0.8 ~speed:7.0 () in
  let max_overshoot = ref 0.0 in
  for _ = 1 to 20_000 do
    move_straight ~mult:1.0 creet;
    let overshoot = List.fold_left max 0.0 [
      creet.radius -. creet.x; creet.x +. creet.radius -. float_of_int area_w;
      creet.radius -. creet.y; creet.y +. creet.radius -. float_of_int area_h ] in
    max_overshoot := max !max_overshoot overshoot
  done;
  check "dépassement maximal < un pas" (!max_overshoot <= 7.0)

let test_move_dropped_outside_comes_back () =
  (* Lâché loin hors de la zone, le Creet repart de là et revient dans la zone. *)
  let creet = make_creet ~x:(-200.) ~y:(-150.) ~dx:(-0.6) ~dy:(-0.8) ~speed:2.0 () in
  let start_x = creet.x in
  move_straight ~mult:1.0 creet;
  check "pas de téléportation au premier tick" (abs_float (creet.x -. start_x) <= 2.0);
  for _ = 1 to 500 do move_straight ~mult:1.0 creet done;
  check "revenu dans la zone"
    (creet.x > 0. && creet.x < float_of_int area_w && creet.y > 0. && creet.y < float_of_int area_h)

let test_move_mult_zero () =
  let creet = make_creet ~x:100. ~y:200. () in
  move_straight ~mult:0.0 creet;
  check "mult = 0 : immobile" (creet.x = 100. && creet.y = 200.)

(* ================================================================
   CHANGEMENTS DE DIRECTION ET APPARITION
   ================================================================ *)

let test_direction_change_probability () =
  check "tirage 0.0 : change"   (should_change_direction 0.0);
  check "tirage 0.24 : change"  (should_change_direction 0.24);
  check "tirage 0.25 : garde"   (not (should_change_direction 0.25));
  check "tirage 0.99 : garde"   (not (should_change_direction 0.99))

let test_direction_change_not_too_frequent () =
  (* En moyenne un virage toutes les dir_change_s / dir_change_prob secondes : entre 5 et 30 s. *)
  let mean_interval = dir_change_s /. dir_change_prob in
  check "virage moyen entre 5 et 30 s" (mean_interval >= 5.0 && mean_interval <= 30.0)

let test_spawn_position_bounds () =
  List.iter (fun (roll_x, roll_y) ->
    let (x, y) = spawn_position ~roll_x ~roll_y in
    let creet = make_creet ~x ~y () in
    check "dans la zone" (x -. creet.radius > 0. && x +. creet.radius < float_of_int area_w);
    check "hors rivière" (not (in_river creet));
    check "hors hôpital" (not (in_hospital creet) && y +. creet.radius < float_of_int (area_h - hospital_h))
  ) [(0., 0.); (0.999, 0.999); (0.5, 0.5); (0., 0.999); (0.999, 0.)]

let test_spawn_position_spread () =
  let (x_min, y_min) = spawn_position ~roll_x:0. ~roll_y:0. in
  let (x_max, y_max) = spawn_position ~roll_x:1. ~roll_y:1. in
  check "occupe presque toute la largeur"   (x_max -. x_min > 0.8 *. float_of_int area_w);
  check "bande verticale non vide"          (y_max -. y_min > 200.)

(* ================================================================
   COMPORTEMENT DU MEAN — poursuite du Sain le plus proche
   ================================================================ *)

let test_mean_chases_right () =
  let mean_creet = make_creet ~id:1 ~x:100. ~y:100. ~dx:0. ~dy:1. ~health:Mean () in
  let target     = make_creet ~id:2 ~x:200. ~y:100. ~health:Healthy () in
  move_toward_nearest_healthy ~mult:0. [mean_creet; target] mean_creet;
  check "se tourne vers la droite" (float_approx_eq mean_creet.dx 1.0)

let test_mean_chases_nearest () =
  let mean_creet = make_creet ~id:1 ~x:100. ~y:100. ~health:Mean () in
  let near       = make_creet ~id:2 ~x:100. ~y:50.  ~health:Healthy () in
  let far        = make_creet ~id:3 ~x:500. ~y:100. ~health:Healthy () in
  move_toward_nearest_healthy ~mult:0. [far; mean_creet; near] mean_creet;
  check "vise le plus proche (vers le haut)" (float_approx_eq mean_creet.dy (-1.0))

let test_nearest_healthy_ignores_non_healthy () =
  let mean_creet = make_creet ~id:1 ~x:0. ~y:0. ~health:Mean () in
  let others = List.map (fun health -> make_creet ~x:10. ~y:0. ~health ()) [Sick; Berserk; Mean; Dead] in
  check "aucune cible parmi les non-Sains" (nearest_healthy (mean_creet :: others) mean_creet = None)

let test_mean_no_target_keeps_direction () =
  let mean_creet = make_creet ~id:1 ~x:100. ~y:100. ~dx:0.6 ~dy:0.8 ~health:Mean () in
  let sick       = make_creet ~id:2 ~x:200. ~y:100. ~health:Sick () in
  move_toward_nearest_healthy ~mult:0. [mean_creet; sick] mean_creet;
  check "sans cible : direction conservée" (float_approx_eq mean_creet.dx 0.6 && float_approx_eq mean_creet.dy 0.8)

let test_mean_direction_unit () =
  let mean_creet = make_creet ~id:1 ~x:0. ~y:0. ~health:Mean () in
  let target     = make_creet ~id:2 ~x:300. ~y:400. ~health:Healthy () in
  move_toward_nearest_healthy ~mult:0. [mean_creet; target] mean_creet;
  check "direction unitaire vers (0.6, 0.8)" (float_approx_eq mean_creet.dx 0.6 && float_approx_eq mean_creet.dy 0.8)

let test_mean_catches_static_target () =
  (* En poursuivant une cible immobile, le Mean finit par la toucher. *)
  let mean_creet = make_creet ~id:1 ~x:100. ~y:300. ~health:Mean ~radius:(20. *. mean_shrink) () in
  let target     = make_creet ~id:2 ~x:700. ~y:150. ~health:Healthy () in
  let ticks = ref 0 in
  while not (touching mean_creet target) && !ticks < 1000 do
    move_toward_nearest_healthy ~mult:1.0 [mean_creet; target] mean_creet;
    incr ticks
  done;
  check "contact atteint" (touching mean_creet target);
  check "en moins de 400 ticks (~6 s)" (!ticks < 400)

let test_mean_distance_decreases () =
  let mean_creet = make_creet ~id:1 ~x:100. ~y:300. ~health:Mean () in
  let target     = make_creet ~id:2 ~x:400. ~y:300. ~health:Healthy () in
  let before = distance_between mean_creet target in
  move_toward_nearest_healthy ~mult:1.0 [mean_creet; target] mean_creet;
  check "se rapproche" (distance_between mean_creet target < before)

(* ================================================================
   CONTAMINATION — rivière
   ================================================================ *)

let test_river_contaminates_healthy () =
  let creet = make_creet ~y:30. () in
  check "retourne vrai" (river_contaminates creet);
  check "devient Malade" (creet.health = Sick)

let test_river_dragged_immune () =
  let creet = make_creet ~y:30. ~dragged:true () in
  check "tenu : pas contaminé" (not (river_contaminates creet) && creet.health = Healthy)

let test_river_safe_zone_no_effect () =
  let creet = make_creet ~y:300. () in
  check "hors rivière : reste Sain" (not (river_contaminates creet) && creet.health = Healthy)

let test_river_already_sick () =
  List.iter (fun health ->
    let creet = make_creet ~y:30. ~health () in
    check "déjà contaminé : pas de nouvelle contamination" (not (river_contaminates creet) && creet.health = health)
  ) [Sick; Berserk; Mean; Dead]

(* ================================================================
   CONTAMINATION — make_sick
   ================================================================ *)

let test_make_sick_healthy () =
  let creet = make_creet () in
  check "Sain → Malade (vrai)" (make_sick creet && creet.health = Sick)

let test_make_sick_other_states () =
  List.iter (fun health ->
    let creet = make_creet ~health () in
    check "autres états inchangés (faux)" (not (make_sick creet) && creet.health = health)
  ) [Sick; Berserk; Mean; Dead]

(* ================================================================
   CONTAMINATION — spread_from (2 % par contact et par itération)
   ================================================================ *)

let pair ?(distance=10.) ?(source=Sick) ?(target=Healthy) ?(dragged=false) () =
  (make_creet ~id:1 ~x:0. ~health:source (), make_creet ~id:2 ~x:distance ~health:target ~dragged ())

let test_spread_contact_100pct () =
  let (source, target) = pair () in
  let infected = spread_from ~chance:1.0 [source; target] source in
  check "Sain contaminé"         (target.health = Sick);
  check "retourné dans la liste" (List.length infected = 1 && List.memq target infected)

let test_spread_contact_0pct () =
  let (source, target) = pair () in
  check "0 % : rien" (spread_from ~chance:0.0 [source; target] source = [] && target.health = Healthy)

let test_spread_no_contact () =
  let (source, target) = pair ~distance:40. () in
  check "tangents : pas de contamination" (spread_from ~chance:1.0 [source; target] source = [] && target.health = Healthy)

let test_spread_dragged_immune () =
  let (source, target) = pair ~dragged:true () in
  check "tenu : invulnérable" (spread_from ~chance:1.0 [source; target] source = [] && target.health = Healthy)

let test_spread_all_contagious_sources () =
  List.iter (fun source_health ->
    let (source, target) = pair ~source:source_health () in
    ignore (spread_from ~chance:1.0 [source; target] source);
    check "toute source contagieuse propage" (target.health = Sick)
  ) [Sick; Berserk; Mean]

let test_spread_non_contagious_sources () =
  List.iter (fun source_health ->
    let (source, target) = pair ~source:source_health () in
    check "Sain ou Mort ne propage pas" (spread_from ~chance:1.0 [source; target] source = [] && target.health = Healthy)
  ) [Healthy; Dead]

let test_spread_only_healthy_targets () =
  List.iter (fun target_health ->
    let (source, target) = pair ~source:Berserk ~target:target_health () in
    ignore (spread_from ~chance:1.0 [source; target] source);
    check "cible non Saine inchangée (ni guérie, ni changée)" (target.health = target_health)
  ) [Sick; Berserk; Mean; Dead]

let test_spread_not_self () =
  let source = make_creet ~health:Sick () in
  check "pas d'auto-contamination" (spread_from ~chance:1.0 [source] source = [])

let test_spread_multiple_targets () =
  let source = make_creet ~id:1 ~x:0. ~health:Sick () in
  let near_a = make_creet ~id:2 ~x:5. () and near_b = make_creet ~id:3 ~x:(-5.) () in
  let far    = make_creet ~id:4 ~x:300. () in
  let infected = spread_from ~chance:1.0 [source; near_a; near_b; far] source in
  check "les deux voisins seulement" (List.length infected = 2 && far.health = Healthy)

let test_spread_berserk_reach_grows () =
  let berserk = make_creet ~id:1 ~x:0. ~health:Berserk ~radius:20. () in
  let target  = make_creet ~id:2 ~x:60. () in
  check "rayon 20 : hors de portée" (spread_from ~chance:1.0 [berserk; target] berserk = []);
  for _ = 1 to 8 do berserk_grow berserk done;
  check "après 8 croissances (rayon ≈ 43) : contact" (spread_from ~chance:1.0 [berserk; target] berserk <> [])

(* Proportion d'infections sur [trials] contacts à la probabilité donnée (graine fixe). *)
let infection_rate ~chance ~trials =
  Random.init 42;
  let count = ref 0 in
  for _ = 1 to trials do
    let (source, target) = pair () in
    if spread_from ~chance [source; target] source <> [] then incr count
  done;
  float_of_int !count /. float_of_int trials

let test_monte_carlo_2pct () =
  let rate = infection_rate ~chance:contam_chance ~trials:100_000 in
  check (Printf.sprintf "taux observé %.4f ≈ 0.02" rate) (rate > 0.018 && rate < 0.022)

let test_monte_carlo_extremes () =
  check "0 %"   (infection_rate ~chance:0.0 ~trials:10_000 = 0.0);
  check "100 %" (infection_rate ~chance:1.0 ~trials:10_000 = 1.0)

let test_monte_carlo_continuous_contact () =
  (* Contact maintenu une seconde (≈ 62 itérations) : 1 - 0.98^62 ≈ 71 % de chance d'être contaminé. *)
  Random.init 7;
  let trials = 20_000 and infected = ref 0 in
  let iterations = int_of_float (1.0 /. tick_s) in
  for _ = 1 to trials do
    let (source, target) = pair () in
    for _ = 1 to iterations do ignore (spread_from ~chance:contam_chance [source; target] source) done;
    if target.health = Sick then incr infected
  done;
  let rate = float_of_int !infected /. float_of_int trials in
  let expected = 1.0 -. (1.0 -. contam_chance) ** float_of_int iterations in
  check (Printf.sprintf "taux %.3f ≈ %.3f" rate expected) (abs_float (rate -. expected) < 0.02)

(* ================================================================
   GUÉRISON — heal_on_drop
   ================================================================ *)

let test_heal_sick_in_hospital () =
  let creet = make_creet ~x:450. ~y:560. ~health:Sick ~speed:1.0 () in
  check "guéri" (heal_on_drop creet);
  check "redevient Sain" (creet.health = Healthy);
  check "vitesse normale" (float_approx_eq creet.speed base_speed);
  check "n'est plus contagieux" (not (is_contagious creet));
  check "vitesse effective pleine" (float_approx_eq (effective_speed ~mult:1.0 creet) base_speed)

let test_heal_sick_outside_hospital () =
  let creet = make_creet ~y:300. ~health:Sick () in
  check "hors hôpital : pas guéri" (not (heal_on_drop creet) && creet.health = Sick)

let test_heal_berserk_mean_never () =
  List.iter (fun health ->
    let creet = make_creet ~x:450. ~y:560. ~health () in
    check "Berserk / Mean jamais guéris" (not (heal_on_drop creet) && creet.health = health)
  ) [Berserk; Mean]

let test_heal_healthy_noop () =
  let creet = make_creet ~x:450. ~y:560. () in
  check "Sain : rien à guérir" (not (heal_on_drop creet) && creet.health = Healthy)

(* ================================================================
   ÉVOLUTION — Berserk et Mean (10 % chacun, exclusifs)
   ================================================================ *)

let test_evolution_of_roll () =
  check "0.00 → Berserk" (evolution_of_roll 0.00 = Berserk);
  check "0.09 → Berserk" (evolution_of_roll 0.09 = Berserk);
  check "0.10 → Mean"    (evolution_of_roll 0.10 = Mean);
  check "0.19 → Mean"    (evolution_of_roll 0.19 = Mean);
  check "0.20 → Malade"  (evolution_of_roll 0.20 = Sick);
  check "0.99 → Malade"  (evolution_of_roll 0.99 = Sick)

let test_evolve_to_berserk () =
  let creet = make_creet ~health:Sick () in
  check "devient Berserk" (evolve ~roll:0.05 creet = Berserk && creet.health = Berserk);
  check "taille inchangée" (float_approx_eq creet.radius (float_of_int creet_r))

let test_evolve_to_mean () =
  let creet = make_creet ~health:Sick () in
  check "devient Mean" (evolve ~roll:0.15 creet = Mean && creet.health = Mean);
  check "rétrécit à 85 %" (float_approx_eq creet.radius (float_of_int creet_r *. 0.85))

let test_evolve_stays_sick () =
  let creet = make_creet ~health:Sick () in
  check "reste Malade" (evolve ~roll:0.5 creet = Sick && float_approx_eq creet.radius (float_of_int creet_r))

let test_evolve_only_sick () =
  List.iter (fun health ->
    let creet = make_creet ~health () in
    check "seul un Malade évolue" (evolve ~roll:0.05 creet = health && evolve ~roll:0.15 creet = health)
  ) [Healthy; Berserk; Mean; Dead]

let test_evolve_permanent () =
  (* Une fois Berserk ou Mean, le Creet le reste jusqu'à sa mort, quel que soit le tirage. *)
  let berserk = make_creet ~health:Sick () and mean = make_creet ~health:Sick () in
  ignore (evolve ~roll:0.05 berserk); ignore (evolve ~roll:0.15 mean);
  List.iter (fun roll -> ignore (evolve ~roll berserk); ignore (evolve ~roll mean)) [0.0; 0.15; 0.5];
  check "Berserk reste Berserk" (berserk.health = Berserk);
  check "Mean reste Mean, rétréci une seule fois"
    (mean.health = Mean && float_approx_eq mean.radius (float_of_int creet_r *. 0.85))

let test_evolve_distribution () =
  Random.init 2024;
  let trials = 100_000 and berserk = ref 0 and mean = ref 0 in
  for _ = 1 to trials do
    match evolve ~roll:(Random.float 1.0) (make_creet ~health:Sick ()) with
    | Berserk -> incr berserk
    | Mean    -> incr mean
    | _       -> ()
  done;
  let rate count = float_of_int !count /. float_of_int trials in
  check (Printf.sprintf "Berserk %.3f ≈ 0.10" (rate berserk)) (abs_float (rate berserk -. 0.10) < 0.005);
  check (Printf.sprintf "Mean %.3f ≈ 0.10" (rate mean))       (abs_float (rate mean -. 0.10) < 0.005)

(* ================================================================
   BERSERK — croissance de 10 % toutes les 10 s, mort à 4× le diamètre
   ================================================================ *)

let test_berserk_grow_10pct () =
  let creet = make_creet ~radius:20. () in
  berserk_grow creet;
  check "diamètre +10 %" (float_approx_eq creet.radius 22.)

let test_berserk_death_threshold () =
  check "rayon 20 : vivant"   (not (berserk_should_die (make_creet ~radius:20. ())));
  check "rayon 79.9 : vivant" (not (berserk_should_die (make_creet ~radius:79.9 ())));
  check "rayon 80 (4×) : mort" (berserk_should_die (make_creet ~radius:80. ()))

let test_berserk_lifetime_2min30 () =
  (* 20 × 1.1^n ≥ 80 ⇔ n ≥ 14.5 → 15 croissances × 10 s = 150 s = 2 min 30. *)
  let creet = make_creet ~health:Berserk ~radius:(float_of_int creet_r) () in
  let steps = ref 0 in
  while not (berserk_should_die creet) do berserk_grow creet; incr steps done;
  let lifetime = float_of_int !steps *. grow_s in
  check (Printf.sprintf "mort après %d croissances (%.0f s)" !steps lifetime) (!steps = 15 && lifetime = 150.)

(* ================================================================
   FIN DE PARTIE — plus aucun Creet Sain
   ================================================================ *)

let creets_with states = List.mapi (fun id health -> make_creet ~id ~health ()) states

let test_gameover_with_healthy () =
  check "un Sain : continue"            (not (game_is_over (creets_with [Healthy])));
  check "Sain parmi d'autres : continue" (not (game_is_over (creets_with [Sick; Berserk; Healthy; Mean; Dead])))

let test_gameover_no_healthy () =
  check "que des Malades : terminé"     (game_is_over (creets_with [Sick; Sick]));
  check "Malade + Berserk + Mean : fin" (game_is_over (creets_with [Sick; Berserk; Mean]));
  check "tous morts : terminé"          (game_is_over (creets_with [Dead; Dead]));
  check "liste vide : terminé"          (game_is_over [])

let test_gameover_dragged_healthy_counts () =
  check "un Sain tenu par le joueur compte comme vivant"
    (not (game_is_over [make_creet ~health:Healthy ~dragged:true (); make_creet ~health:Sick ()]))

(* ================================================================
   DIFFICULTÉ — accélération progressive
   ================================================================ *)

let test_accel_increases () =
  check "le multiplicateur augmente" (next_speed_mult 1.0 > 1.0)

let test_accel_curve () =
  let mult_after seconds = let m = ref 1.0 in for _ = 1 to seconds do m := next_speed_mult !m done; !m in
  check "1 min : encore facile (< ×1.3)"     (mult_after 60 < 1.3);
  check "5 min : nettement plus dur (> ×2)"  (mult_after 300 > 2.0);
  check "10 min : intenable (> ×5)"          (mult_after 600 > 5.0)

(* ================================================================
   AFFICHAGE — une couleur (classe CSS) distincte par état
   ================================================================ *)

let test_health_classes_distinct () =
  let classes = List.map health_class all_states in
  check "5 classes distinctes" (List.length (List.sort_uniq compare classes) = List.length all_states)

let test_health_classes_values () =
  check "valeurs attendues par la feuille de style"
    (List.map health_class [Healthy; Sick; Berserk; Mean] = ["healthy"; "sick"; "berserk"; "mean"])

(* ================================================================
   CONSTANTES DU SUJET
   ================================================================ *)

let test_subject_constants () =
  check "contamination 2 %"         (float_approx_eq contam_chance 0.02);
  check "Berserk 10 %"              (float_approx_eq berserk_prob 0.10);
  check "Mean 10 %"                 (float_approx_eq mean_prob 0.10);
  check "Malade 15 % plus lent"     (float_approx_eq sick_factor 0.85);
  check "évolution toutes les 10 s" (float_approx_eq evolve_s 10.0);
  check "croissance toutes les 10 s" (float_approx_eq grow_s 10.0);
  check "croissance de 10 %"        (float_approx_eq grow_factor 1.10);
  check "mort Berserk à 4×"         (float_approx_eq max_size_mult 4.0);
  check "Mean 15 % plus petit"      (float_approx_eq mean_shrink 0.85);
  check "Mean vit 1 minute"         (float_approx_eq mean_life_s 60.0)

let test_population_constants () =
  check "population initiale 5-10"   (init_count >= 5 && init_count <= 10);
  check "naissance toutes les quelques secondes" (spawn_s >= 2.0 && spawn_s <= 10.0);
  check "Creets assez gros pour être saisis" (creet_r >= 10 && creet_r <= 40)

let test_zone_constants () =
  check "rivière et hôpital disjoints" (river_h < area_h - hospital_h);
  check "bande de jeu assez haute"     (area_h - hospital_h - river_h > 4 * creet_r)

(* ================================================================
   ENREGISTREMENT ALCOTEST
   ================================================================ *)

let quick name f = Alcotest.test_case name `Quick f

let () =
  Alcotest.run "H42N42 — logique du jeu" [
    "création", [
      quick "valeurs par défaut"   test_make_creet_defaults;
      quick "direction unitaire"   test_make_creet_direction_unit;
      quick "angle"                test_make_creet_angle;
      quick "set_direction"        test_set_direction;
    ];
    "états", [
      quick "contagieux"           test_contagious_states;
      quick "saisissables"         test_grab_states;
    ];
    "géométrie : distance", [
      quick "même point"           test_dist_same_point;
      quick "3-4-5"                test_dist_345_triangle;
      quick "symétrique"           test_dist_symmetric;
      quick "hors zone"            test_dist_negative_coords;
      quick "diagonale"            test_dist_max_arena;
      quick "inégalité triangulaire" test_dist_triangle_inequality;
    ];
    "géométrie : contact", [
      quick "tangents"             test_touching_exact_boundary;
      quick "chevauchement"        test_touching_overlap;
      quick "éloignés"             test_touching_far_apart;
      quick "diagonale"            test_touching_diagonal;
      quick "rayons différents"    test_touching_different_radii;
      quick "Berserk"              test_touching_berserk_large_radius;
      quick "Mean"                 test_touching_mean_small_radius;
      quick "symétrie"             test_touching_symmetric;
    ];
    "géométrie : normalize", [
      quick "3-4-5"                test_normalize_345;
      quick "vecteur nul"          test_normalize_zero_vector;
      quick "longueur 1"           test_normalize_unit_length;
      quick "idempotent"           test_normalize_idempotent;
    ];
    "zone : rivière", [
      quick "centre"               test_river_center_deep_in;
      quick "bord du cercle"       test_river_edge_touching;
      quick "tangent"              test_river_exactly_on_boundary;
      quick "zone de jeu"          test_river_safe_zone;
      quick "au-dessus de la zone" test_river_above_area;
      quick "Berserk grossi"       test_river_grown_berserk;
    ];
    "zone : hôpital", [
      quick "centre"               test_hospital_center_in;
      quick "limite haute"         test_hospital_top_boundary;
      quick "bord seul"            test_hospital_only_edge_overlapping;
      quick "limite basse"         test_hospital_bottom_boundary;
      quick "limites horizontales" test_hospital_horizontal_limits;
      quick "zone de jeu"          test_hospital_safe_zone;
    ];
    "déplacement : rebonds", [
      quick "mur gauche"           test_bounce_left_wall;
      quick "mur droit"            test_bounce_right_wall;
      quick "mur haut"             test_bounce_top_wall;
      quick "mur bas"              test_bounce_bottom_wall;
      quick "coin"                 test_bounce_corner;
      quick "norme conservée"      test_bounce_preserves_norm;
      quick "angle de réflexion"   test_bounce_angle_reflection;
      quick "zone de jeu"          test_no_bounce_in_play_zone;
      quick "déjà en retour"       test_bounce_moving_inward_unchanged;
      quick "pas de téléportation" test_bounce_never_teleports;
      quick "tangent"              test_bounce_exactly_tangent;
    ];
    "déplacement : vitesse", [
      quick "Sain"                 test_speed_healthy;
      quick "Malade -15 %"         test_speed_sick_15pct_slower;
      quick "tous contaminés -15 %" test_speed_all_contaminated_slower;
      quick "multiplicateur"       test_speed_scales_with_mult;
      quick "zéro"                 test_speed_zero;
    ];
    "déplacement : ligne droite", [
      quick "un pas"               test_move_straight_right;
      quick "Malade"               test_move_straight_sick_slower;
      quick "vitesse constante"    test_move_straight_constant_speed;
      quick "rebond"               test_move_straight_bounces;
      quick "reste dans la zone"   test_move_stays_in_area_long_run;
      quick "lâché hors zone"      test_move_dropped_outside_comes_back;
      quick "immobile"             test_move_mult_zero;
    ];
    "direction et naissance", [
      quick "probabilité de virage" test_direction_change_probability;
      quick "virages peu fréquents" test_direction_change_not_too_frequent;
      quick "position de naissance" test_spawn_position_bounds;
      quick "répartition"           test_spawn_position_spread;
    ];
    "Mean : poursuite", [
      quick "vers la droite"       test_mean_chases_right;
      quick "le plus proche"       test_mean_chases_nearest;
      quick "ignore les non-Sains" test_nearest_healthy_ignores_non_healthy;
      quick "sans cible"           test_mean_no_target_keeps_direction;
      quick "direction unitaire"   test_mean_direction_unit;
      quick "rattrape sa cible"    test_mean_catches_static_target;
      quick "se rapproche"         test_mean_distance_decreases;
    ];
    "contamination : rivière", [
      quick "Sain"                 test_river_contaminates_healthy;
      quick "tenu"                 test_river_dragged_immune;
      quick "hors rivière"         test_river_safe_zone_no_effect;
      quick "déjà contaminé"       test_river_already_sick;
    ];
    "contamination : make_sick", [
      quick "Sain"                 test_make_sick_healthy;
      quick "autres états"         test_make_sick_other_states;
    ];
    "contamination : contact", [
      quick "100 %"                test_spread_contact_100pct;
      quick "0 %"                  test_spread_contact_0pct;
      quick "sans contact"         test_spread_no_contact;
      quick "tenu invulnérable"    test_spread_dragged_immune;
      quick "sources contagieuses" test_spread_all_contagious_sources;
      quick "sources saines"       test_spread_non_contagious_sources;
      quick "cibles saines seules" test_spread_only_healthy_targets;
      quick "pas soi-même"         test_spread_not_self;
      quick "plusieurs cibles"     test_spread_multiple_targets;
      quick "portée du Berserk"    test_spread_berserk_reach_grows;
    ];
    "contamination : statistiques", [
      quick "2 % par itération"    test_monte_carlo_2pct;
      quick "0 % et 100 %"         test_monte_carlo_extremes;
      quick "contact prolongé"     test_monte_carlo_continuous_contact;
    ];
    "guérison", [
      quick "Malade à l'hôpital"   test_heal_sick_in_hospital;
      quick "hors hôpital"         test_heal_sick_outside_hospital;
      quick "Berserk / Mean"       test_heal_berserk_mean_never;
      quick "Sain"                 test_heal_healthy_noop;
    ];
    "évolution", [
      quick "tirages"              test_evolution_of_roll;
      quick "Berserk"              test_evolve_to_berserk;
      quick "Mean"                 test_evolve_to_mean;
      quick "reste Malade"         test_evolve_stays_sick;
      quick "seul un Malade"       test_evolve_only_sick;
      quick "définitif"            test_evolve_permanent;
      quick "répartition 10/10/80" test_evolve_distribution;
    ];
    "Berserk", [
      quick "+10 %"                test_berserk_grow_10pct;
      quick "seuil de mort"        test_berserk_death_threshold;
      quick "durée de vie 2 min 30" test_berserk_lifetime_2min30;
    ];
    "fin de partie", [
      quick "avec un Sain"         test_gameover_with_healthy;
      quick "sans Sain"            test_gameover_no_healthy;
      quick "Sain tenu"            test_gameover_dragged_healthy_counts;
    ];
    "difficulté", [
      quick "accélération"         test_accel_increases;
      quick "courbe"               test_accel_curve;
    ];
    "affichage", [
      quick "classes distinctes"   test_health_classes_distinct;
      quick "noms des classes"     test_health_classes_values;
    ];
    "constantes", [
      quick "valeurs du sujet"     test_subject_constants;
      quick "population"           test_population_constants;
      quick "zones"                test_zone_constants;
    ];
  ]
