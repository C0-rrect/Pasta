#include "Authorization.h"
#include <Security/Authorization.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *pasta_import_authorize(const char *tool, char *const arguments[], PastaProgressCallback callback, void *context) {
    AuthorizationRef auth=NULL;
    if(AuthorizationCreate(NULL,kAuthorizationEmptyEnvironment,kAuthorizationFlagDefaults,&auth)!=errAuthorizationSuccess)
        return strdup("RESULT\tERROR\t无法创建管理员授权。");
    FILE *stream=NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status=AuthorizationExecuteWithPrivileges(auth,tool,kAuthorizationFlagDefaults,arguments,&stream);
#pragma clang diagnostic pop
    if(status!=errAuthorizationSuccess) {
        AuthorizationFree(auth,kAuthorizationFlagDestroyRights);
        return strdup(status==errAuthorizationCanceled?"RESULT\tERROR\t已取消，没有开始导入。":"RESULT\tERROR\t未取得管理员授权。");
    }
    char *line=NULL, *result=NULL; size_t capacity=0;
    if(stream) {
        while(getline(&line,&capacity,stream)>=0) {
            line[strcspn(line,"\r\n")]=0;
            if(!strncmp(line,"PROGRESS\t",9) && callback) callback(line,context);
            if(!strncmp(line,"RESULT\t",7)) { free(result); result=strdup(line); }
        }
        fclose(stream);
    }
    free(line);AuthorizationFree(auth,kAuthorizationFlagDestroyRights);
    return result?result:strdup("RESULT\tERROR\t导入进程未返回完成结果，请检查硬盘连接。源文件未删除。");
}
