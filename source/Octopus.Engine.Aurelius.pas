unit Octopus.Engine.Aurelius;

interface

uses
  System.Rtti,
  Generics.Collections,
  Aurelius.Drivers.Interfaces,
  Octopus.Persistence.Common,
  Octopus.Persistence.Aurelius,
  Octopus.Process,
  Octopus.Engine,
  Octopus.Engine.Runner;

type
  IAureliusStorage = interface(IStorage)
  ['{B44D57EE-E5CC-4B7E-BFDA-57A5C635003A}']
    function GetPool: IDBConnectionPool;
    property Pool: IDBConnectionPool read GetPool;
  end;

  TAureliusStorage = class(TInterfacedObject, IAureliusStorage)
  strict private
    FPool: IDBConnectionPool;
    function GetPool: IDBConnectionPool;
  public
    constructor Create(APool: IDBConnectionPool);
    property Pool: IDBConnectionPool read GetPool;
  end;

  TAureliusOctopusEngine = class(TInterfacedObject, IOctopusEngine)
  strict private
    FPool: IDBConnectionPool;
    FProcessFactory: IOctopusProcessFactory;
    FLockTimeoutMS: Integer;
    function CreateRepository: IOctopusRepository;
    function CreateRuntime: IOctopusRuntime;
    function CreateInstanceService(const InstanceId: string): IOctopusInstanceService;
    procedure RunInstance(Process: TWorkflowProcess; Instance: IProcessInstanceData;
      Variables: IVariablesPersistence); overload;
  public
    constructor Create(APool: IDBConnectionPool); overload;
    constructor Create(APool: IDBConnectionPool; AProcessFactory: IOctopusProcessFactory); overload;
    property Pool: IDBConnectionPool read FPool;
  public
    { IOctopusEngine methods }
    function PublishDefinition(const Key, Process: string; const Name: string = ''): string;
    function FindDefinitionByKey(const Key: string): IProcessDefinition;

    function CreateInstance(const ProcessId: string): string; overload;
    function CreateInstance(const ProcessId: string; Variables: TEnumerable<TVariable>): string; overload;
    function CreateInstance(const ProcessId, Reference: string): string; overload;
    function CreateInstance(const ProcessId, Reference: string; Variables: TEnumerable<TVariable>): string; overload;
    procedure RunInstance(const InstanceId: string); overload;

    procedure SetVariable(const InstanceId, VariableName: string; const Value: TValue);
    function GetVariable(const InstanceId, VariableName: string): IVariable;
    function FindInstances: IInstanceQuery;

    procedure RunPendingInstances;
  end;

implementation

{ TAureliusOctopusEngine }

constructor TAureliusOctopusEngine.Create(APool: IDBConnectionPool);
begin
  Create(APool, nil);
end;

constructor TAureliusOctopusEngine.Create(APool: IDBConnectionPool;
  AProcessFactory: IOctopusProcessFactory);
begin
  inherited Create;
  FLockTimeoutMS := 5 * 60 * 1000; // 5 minutes
  FPool := APool;
  FProcessFactory := AProcessFactory;
end;

function TAureliusOctopusEngine.CreateInstance(const ProcessId,
  Reference: string; Variables: TEnumerable<TVariable>): string;
var
  Instance: IProcessInstanceData;
  VariablesPersistence: IVariablesPersistence;
  Process: TWorkflowProcess;
  Variable: TVariable;
begin
  Process := CreateRepository.GetDefinition(ProcessId);
  try
    Result := CreateRuntime.CreateInstance(ProcessId, Reference);
    Instance := TAureliusInstanceData.Create(Pool, Result);
    VariablesPersistence := TAureliusInstanceService.Create(Pool, Result);
    Process.InitInstance(Instance, VariablesPersistence);
  finally
    Process.Free;
  end;
  if Variables <> nil then
    for Variable in Variables do
      VariablesPersistence.SaveVariable(Variable.Name, Variable.Value);
end;

function TAureliusOctopusEngine.CreateInstanceService(const InstanceId: string): IOctopusInstanceService;
begin
  Result := TAureliusInstanceService.Create(Pool, InstanceId);
end;

function TAureliusOctopusEngine.CreateInstance(const ProcessId,
  Reference: string): string;
begin
  Result := CreateInstance(ProcessId, Reference, nil);
end;

function TAureliusOctopusEngine.CreateInstance(const ProcessId: string): string;
begin
  Result := CreateInstance(ProcessId, '', nil);
end;

function TAureliusOctopusEngine.CreateInstance(const ProcessId: string;
  Variables: TEnumerable<TVariable>): string;
begin
  Result := CreateInstance(ProcessId, '', Variables);
end;

function TAureliusOctopusEngine.CreateRepository: IOctopusRepository;
begin
  Result := TAureliusRepository.Create(Pool, FProcessFactory);
end;

function TAureliusOctopusEngine.CreateRuntime: IOctopusRuntime;
begin
  Result := TAureliusRuntime.Create(Pool);
end;

function TAureliusOctopusEngine.FindDefinitionByKey(
  const Key: string): IProcessDefinition;
begin
  Result := CreateRepository.FindDefinitionByKey(Key);
end;

function TAureliusOctopusEngine.FindInstances: IInstanceQuery;
begin
  Result := CreateRuntime.CreateInstanceQuery;
end;

function TAureliusOctopusEngine.GetVariable(const InstanceId, VariableName: string): IVariable;
begin
  Result := CreateInstanceService(InstanceId).LoadVariable(VariableName);
end;

function TAureliusOctopusEngine.PublishDefinition(const Key, Process: string; const Name: string = ''): string;
begin
  Result := CreateRepository.PublishDefinition(Key, Process, Name);
end;

procedure TAureliusOctopusEngine.RunInstance(Process: TWorkflowProcess;
  Instance: IProcessInstanceData; Variables: IVariablesPersistence);
var
  runner: TWorkflowRunner;
  storage: IAureliusStorage;
begin
  storage := TAureliusStorage.Create(Self.Pool);
  runner := TWorkflowRunner.Create(Process, Instance, Variables, storage);
  try
    runner.Execute;
  finally
    runner.Free;
  end;
end;

procedure TAureliusOctopusEngine.RunInstance(const InstanceId: string);
var
  Process: TWorkflowProcess;
  ProcessId: string;
  Instance: IProcessInstanceData;
  VariablesPersistence: IVariablesPersistence;
begin
  ProcessId := CreateRuntime.GetInstanceProcessId(InstanceId);
  Process := CreateRepository.GetDefinition(ProcessId);
  try
    Instance := TAureliusInstanceData.Create(Pool, InstanceId);
    VariablesPersistence := TAureliusInstanceService.Create(Pool, InstanceId);
    RunInstance(Process, Instance, VariablesPersistence);
  finally
    Process.Free;
  end;
end;

procedure TAureliusOctopusEngine.RunPendingInstances;
var
  Runtime: IOctopusRuntime;
  Instance: IProcessInstance;
begin
  Runtime := CreateRuntime;
  for Instance in Runtime.GetPendingInstances do
    RunInstance(Instance.Id)
end;

procedure TAureliusOctopusEngine.SetVariable(const InstanceId,
  VariableName: string; const Value: TValue);
var
  Instance: IProcessInstanceData;
begin
  Instance := TAureliusInstanceData.Create(Pool, InstanceId);
  Instance.Lock(FLockTimeoutMS);
  try
    CreateInstanceService(InstanceId).SaveVariable(VariableName, Value);
  finally
    Instance.Unlock;
  end;

end;

{ TAureliusStorage }

constructor TAureliusStorage.Create(APool: IDBConnectionPool);
begin
  inherited Create;
  FPool := APool;
end;

function TAureliusStorage.GetPool: IDBConnectionPool;
begin
  Result := FPool;
end;

end.
