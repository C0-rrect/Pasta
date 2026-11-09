#ifndef PASTA_AUTH_H
#define PASTA_AUTH_H
typedef void (*PastaProgressCallback)(const char *, void *);
char *pasta_import_authorize(const char *tool, char *const arguments[], PastaProgressCallback callback, void *context);
#endif
