/*
 * iOS embedded build: rig control (serial / CM108 / Hamlib) is out of scope.
 * Provide stubs for os_util.h entry points so common code can link.
 */
 
 #include <stdbool.h>
 
 #include "common/os_util.h"
 #include "common/log.h"
 
 HANDLE OpenCOMPort(void *Port, int speed)
 {
 	(void)speed;
 	ZF_LOGW("OpenCOMPort not supported on iOS (%s)", Port ? (const char *)Port : "(null)");
 	return 0;
 }
 
 void CloseCOMPort(HANDLE *fd)
 {
 	if (fd)
 		*fd = 0;
 }
 
 bool COMSetRTS(HANDLE fd) { (void)fd; return false; }
 bool COMClearRTS(HANDLE fd) { (void)fd; return false; }
 bool COMSetDTR(HANDLE fd) { (void)fd; return false; }
 bool COMClearDTR(HANDLE fd) { (void)fd; return false; }
 
 bool WriteCOMBlock(HANDLE fd, unsigned char *Block, int BytesToWrite)
 {
 	(void)fd;
 	(void)Block;
 	(void)BytesToWrite;
 	return false;
 }
 
 int ReadCOMBlock(HANDLE fd, unsigned char *Block, int MaxLength)
 {
 	(void)fd;
 	(void)Block;
 	(void)MaxLength;
 	return 0;
 }
 
 HANDLE OpenCM108(char *devstr)
 {
 	(void)devstr;
 	return 0;
 }
 
 int CM108_set_ptt(HANDLE fd, bool State)
 {
 	(void)fd;
 	(void)State;
 	return -1;
 }
 
 void CloseCM108(HANDLE *fd)
 {
 	if (fd)
 		*fd = 0;
 }
 
 char **GetSerialStrlist(void)
 {
 	return NULL;
 }
 
 char **GetCM108Strlist(void)
 {
 	return NULL;
 }
