# snap-copy
Microsoft Windows script to create a drive snapshot and then mirror a folder using Robocopy

## Example Configuration File

    {
        "destinationPath": "\\\\hostname\\share\\path or D:\\localpath",
        "sourceDrive": "C:",
        "sourcePath": "LocalFolder\\local", 
        "maxShadowCopies": 0,
        "mail" : {
            "sendOnSuccess" : false,
            "sendOnFailure" : true,
            "smtpServer" : "mail.server.com",
            "sender" : "Name <email@address.com",
            "recipients" : "email@address.com,email2@address.com",
            "subject" : "Snap-Copy Results on server.com"
        }
    }
 
 The script looks for the following file in the save folder as the script: snap-copy-config.json
