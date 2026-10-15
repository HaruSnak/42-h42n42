NAME        = h42n42
PORT        ?= 8080

DUNE        = dune
DUNE_FLAGS  = --profile release
BUILD       = _build/default/src

# Fichiers produits : JavaScript client, modules serveur, configuration Ocsigen.
LOCAL       = local
LIBDIR      = $(LOCAL)/lib
LOGDIR      = $(LOCAL)/log
DATADIR     = $(LOCAL)/data
RUNDIR      = $(LOCAL)/run
STATICDIR   = static
JS          = $(STATICDIR)/$(NAME).js
LIBS        = $(addprefix $(LIBDIR)/, logic.cma logic.cmxs $(NAME).cma $(NAME).cmxs)
CONF        = $(NAME).conf

# Toute modification d'une de ces sources déclenche une recompilation, et rien d'autre.
SRCS        = dune-project $(wildcard src/*.eliom src/*.ml src/dune src/client/dune src/tools/dune)

all: $(JS) $(LIBS) $(CONF)

$(JS): $(SRCS)
	$(DUNE) build $(DUNE_FLAGS) src/client/$(NAME).bc.js
	install -m 644 _build/default/src/client/$(NAME).bc.js $@

$(LIBDIR)/%: $(SRCS) | $(LIBDIR)
	$(DUNE) build $(DUNE_FLAGS) src/$*
	install -m 644 $(BUILD)/$* $@

$(CONF): $(NAME).conf.in Makefile | $(LOGDIR) $(DATADIR) $(RUNDIR)
	sed -e 's|@PORT@|$(PORT)|g' \
	    -e 's|@LOGDIR@|$(CURDIR)/$(LOGDIR)|g' \
	    -e 's|@DATADIR@|$(CURDIR)/$(DATADIR)|g' \
	    -e 's|@RUNDIR@|$(CURDIR)/$(RUNDIR)|g' \
	    -e 's|@STATICDIR@|$(CURDIR)/$(STATICDIR)|g' \
	    -e 's|@LIBDIR@|$(CURDIR)/$(LIBDIR)|g' $< > $@

$(LIBDIR) $(LOGDIR) $(DATADIR) $(RUNDIR):
	mkdir -p $@

run: all
	ocsigenserver.opt -c $(CONF)

test:
	$(DUNE) test --force

clean:
	$(DUNE) clean

fclean: clean
	rm -rf $(LOCAL) $(JS) $(CONF) ocsidb

re: fclean all

.PHONY: all run test clean fclean re
