#include <ti/screen.h>
#include <ti/getcsc.h>
#include <fileioc.h>

void PrintText(int8_t xpos, int8_t ypos, const char *text);

int main(void)
{
    /* Declare some variables */
    const char *oldName = "OldFile";
    const char *newName = "NewFile";
    char nameBuffer[10];
    ti_var_t file;
    bool error = true;

    /* Clear the homescreen */
    os_ClrHome();

    /* Delete both the new and old files if they already exist */
    ti_Delete(oldName);
    ti_Delete(newName);

    do
    {
        /* Create a file with the old name */
        file = ti_Open(oldName, "w");
        if (!file) break;

        ti_GetName(nameBuffer, file);
        PrintText(0, 0, "Old Name: ");
        PrintText(10, 0, nameBuffer);

        /* Rename the old file to the new file name */
        ti_Rename(oldName, newName);

        /* Ensure that the slot is closed */
        ti_Close(file);
        file = 0;

        /* Ensure the new name of the file is correct */
        file = ti_Open(newName, "r");
        if (!file) break;

        ti_GetName(nameBuffer, file);
        PrintText(0, 1, "New Name: ");
        PrintText(10, 1, nameBuffer);

        /* Ensure that the slot is closed */
        ti_Close(file);
        file = 0;

        error = false;
    } while (0);

    /* If an error occured, inform the user */
    if (error == true)
    {
        PrintText(0, 2, "An error occured");
    }

    /* Waits for a key */
    while (!os_GetCSC());

    return 0;
}

/* Draw text on the homescreen at the given X/Y location */
void PrintText(int8_t xpos, int8_t ypos, const char *text)
{
    os_SetCursorPos(ypos, xpos);
    os_PutStrFull(text);
}
