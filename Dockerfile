# OCaml 5.2 : la version la plus récente compatible avec Eliom 11 / js_of_ocaml 5.
FROM ocaml/opam:ubuntu-22.04-ocaml-5.2

USER opam
# Créé par l'utilisateur opam : un WORKDIR seul appartiendrait à root et le build ne pourrait pas y écrire.
RUN mkdir -p /home/opam/h42n42
WORKDIR /home/opam/h42n42

# Dépendances : Eliom (Ocsigen server, js_of_ocaml, Lwt, TyXML), le stockage persistant
# requis par Eliom et Alcotest pour les tests. opam installe lui-même les paquets
# système nécessaires (libgmp, libssl, libsqlite3...) grâce à --confirm-level=unsafe-yes.
RUN sudo apt-get update \
 && opam install -y --confirm-level=unsafe-yes \
      eliom.11.1.1 \
      ocsipersist-sqlite.2.0.0 \
      alcotest \
 && sudo rm -rf /var/lib/apt/lists/*

COPY --chown=opam:opam . .

# Compile le serveur et le client (OCaml → JavaScript), puis lance les tests unitaires.
RUN opam exec -- make all && opam exec -- make test

EXPOSE 8080

CMD ["opam", "exec", "--", "ocsigenserver.opt", "-c", "h42n42.conf"]
