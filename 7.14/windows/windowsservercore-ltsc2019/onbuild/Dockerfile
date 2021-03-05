#escape=`
FROM advantys/workflowgen:7.14.12-win-ltsc2019

# Customization point for WorkflowGen's files, libraries and modules as well as
# IIS configuration files.
ONBUILD COPY .\inetpub\wwwroot C:\inetpub\wwwroot
# Customization point for WorkflowGen's Windows Services
ONBUILD COPY [ ".\\Program Files\\Advantys\\WorkflowGen", "C:\\Program Files\\Advantys\\WorkflowGen" ]
