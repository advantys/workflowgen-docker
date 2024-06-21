#escape=`
FROM advantys/workflowgen:9.0.2-win-ltsc2019

# Customization point for WorkflowGen's files, libraries and modules as well as
# web.config files.
ONBUILD COPY .\inetpub\wwwroot C:\inetpub\wwwroot
# Customization point for WorkflowGen's Windows Services
ONBUILD COPY [ ".\\Program Files\\Advantys\\WorkflowGen", "C:\\Program Files\\Advantys\\WorkflowGen" ]
