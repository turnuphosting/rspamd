#ifndef CLASSIFIERS_H
#define CLASSIFIERS_H

#include "../config.h"
#include "../mem_pool.h"
#include "../statfile.h"
#include "../tokenizers/tokenizers.h"

/* Consider this value as 0 */
#define ALPHA 0.0001

struct classifier_config;
struct worker_task;

struct classifier_ctx {
	memory_pool_t *pool;
	GHashTable *results;
	struct classifier_config *cfg;
};

struct classify_weight {
	const char *name;
	long double weight;
};

/* Common classifier structure */
struct classifier {
	char *name;
	struct classifier_ctx* (*init_func)(memory_pool_t *pool, struct classifier_config *cf);
	gboolean (*classify_func)(struct classifier_ctx* ctx, statfile_pool_t *pool, GTree *input, struct worker_task *task);
	gboolean (*learn_func)(struct classifier_ctx* ctx, statfile_pool_t *pool,
							const char *symbol, GTree *input, gboolean in_class,
							double *sum, double multiplier, GError **err);
	GList* (*weights_func)(struct classifier_ctx* ctx, statfile_pool_t *pool, GTree *input, struct worker_task *task);
};

/* Get classifier structure by name or return NULL if this name is not found */
struct classifier* get_classifier (char *name);

/* Winnow algorithm */
struct classifier_ctx* winnow_init (memory_pool_t *pool, struct classifier_config *cf);
gboolean winnow_classify (struct classifier_ctx* ctx, statfile_pool_t *pool, GTree *input, struct worker_task *task);
gboolean winnow_learn (struct classifier_ctx* ctx, statfile_pool_t *pool, const char *symbol, GTree *input,
				gboolean in_class, double *sum, double multiplier, GError **err);
GList *winnow_weights (struct classifier_ctx* ctx, statfile_pool_t *pool, GTree *input, struct worker_task *task);

/* Bayes algorithm */
struct classifier_ctx* bayes_init (memory_pool_t *pool, struct classifier_config *cf);
gboolean bayes_classify (struct classifier_ctx* ctx, statfile_pool_t *pool, GTree *input, struct worker_task *task);
gboolean bayes_learn (struct classifier_ctx* ctx, statfile_pool_t *pool, const char *symbol, GTree *input,
				gboolean in_class, double *sum, double multiplier, GError **err);
GList *bayes_weights (struct classifier_ctx* ctx, statfile_pool_t *pool, GTree *input, struct worker_task *task);
/* Array of all defined classifiers */
extern struct classifier classifiers[];

#endif
/*
 * vi:ts=4
 */
