 function [P, F, E, Error, exitReason] = MacMicUnmix(pixelData, parameters);
%function [P, F, E, Error, exitReason] = MacMicUnmix(X, parameters);

%INPUT
%pixelData  - input hyperspectral pixel data row vectors are pixel spectra (N x D)
%M          - number of endmembers to find in data
%parameters - See MacMicUnmixParameters
%
%OUTPUT
%P          - proportions of macroscopic mixture, colum vectors are endmember proportions for the given pixel
%F          - proportions of microscopic mixture, colum vectors are endmember proportions for the given pixel
%E          - extracted endmembers from data, columns are endmember spectra
%Error     - RSMEreg error as in ICE
%extiReason - gives reason  for alg. termination
%figHandles - handle to all figures created by alg

exitReason = -1;
%ASSIGN PARAMETERS TO VARIABLES WITH SHORTER NAMES
M              = parameters.M;
vcaE           = parameters.vcaEndmembers;
muReg          = parameters.mu;
startingE      = parameters.startingEndmembers;
learningDivide = parameters.learningDivide;
PASS           = parameters.PASS;
VERBOSE        = parameters.VERBOSE;

%TRANSPOSE DATA BECAUSE ORIGINALLY WRITTEN DIFFERENT THAN CURRENT
%CONVENTION
pixelData      = pixelData';
D              = size(pixelData,1);
N              = size(pixelData,2);

%CREATE ALBEDO & REFLECTANCE CONVERSION PARAMETERS AND STRUCTURE
angleEmergence     = -70;%0;
angleIncidence     =  70;%0;
mu                 = cosd(angleEmergence);
mu0                = cosd(angleIncidence);
s                  = mu0+mu;
t                  = (4*s)/((1+2*mu0)*(1+2*mu));
almosta            = 4*mu0*mu*t;
almostb            = 2*s*t; %b without r divided by 2
convStruct.s       = s;
convStruct.t       = t;
convStruct.almosta = almosta;
convStruct.almostb = almostb;
convStruct.mu      = mu;
convStruct.mu0     = mu0;

%CREATE CONSTRAINT MATRICES
OptParams.M            = M;
OptParams.N            = N;
OptParams.Aeq          = ones([1, M]);
OptParams.beq          = 1;
OptParams.lb           = zeros([M, 1]);
OptParams.ub           = ones([M,1]);
OptParams.AeqR         = ones([1, M+1]);
OptParams.beqR         = 1;
OptParams.lbR          = zeros([M+1, 1]);
OptParams.ubR          = ones([M+1,1]);
OptParams.ConstErrFlag = 0.01;   %off by 0.01% indicates error

%GET ENDMEMBERS
if vcaE == 1
    fprintf('Running VCA...\n');
    tic
    [E ~, ~] = VCA( pixelData, 'Endmembers', M);
    toc
    fprintf('Done Running VCA...\n');
else
    E=double(startingE);
end
figure(1234);plot(E); title('Initial Endmembers');drawnow

fprintf('Looking up Albedo 3...\n');
tic
dataW = lookupAlbedo3(pixelData, convStruct);
toc
fprintf('Done Looking up Albedo 3...\n');

tic
[P, F, Error, RSSsum] = MacMicUpdateProps(E, pixelData, dataW, [], muReg, convStruct, OptParams);
%[P, F, Error, RSSsum] = MacMicUpdateProps(E, pixelData, dataW, [], muReg, convStruct, OptParams);
toc

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%I put this here just to see what would happen
% for k = 1:25
%     [P, F, Error, RSSsum] = MacMicUpdateProps(E, pixelData, dataW, [], muReg, convStruct, OptParams);
% end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

if (parameters.EstimateEndmembers == 1);%vcaEndmembers == 0
    exitReason    = 1;
    maxIterations = 120;
    %iteratively train the model
    for countIter = 1:maxIterations
        prevError = Error;
        Estep     = 0;
        for j=1:M
            W            = lookupAlbedo3(E, convStruct);
            derFunc      = zeros(D,1);
            secondDer    = zeros(D,1);
            derAlbEndmem = SlopeRInverse(W(:,j), convStruct);
            %added to slice variables for parfor loop
            sliceP      = P(M+1,:);
            largeSliceP = P(1:M,:);
            sliceF      = F(j,:);
            for i = 1:N
                %parfor i=1:N
                derRefFunct = slopeOfReflectanceCurve2(W*F(:,i), convStruct);
                derFunc     = derFunc + (P(j,i) + sliceP(i).*sliceF(i).*derRefFunct.*derAlbEndmem).*(pixelData(:,i) - E*largeSliceP(:,i) - sliceP(i).*convertToReflectance2(W*F(:,i), convStruct));
                secondDer   = secondDer + (P(j,i) + sliceP(:,i).*sliceF(:,i).*derRefFunct.*derAlbEndmem).^2;
            end
%             No averaging
%             dF            = (-2).*((1-muReg)/N).*derFunc;
            dF             = (-2).*(1-muReg).*derFunc;
            scalingParams  = 2*(muReg/(M*(M-1)));
            for k=1:M
                if j ~= k
                    dF = dF + scalingParams.*(E(:,j) - E(:,k));
                end
            end
            
            secondDerivative = 2.*(1-muReg).*secondDer + 2*(mu/(M*(M-1)))*(M-1);
            dF = dF./secondDerivative;
            
            eta = 10;
            newStep = 0;
            while(eta > 1e-8)
                %%%UPDATE THE jth ENDMEMBER
                tempEndmembers                    = E;
                tempEndmembers(:,j)               = E(:,j) - eta*dF;
                [newP, newF, newError, newRSSsum] = MacMicUpdateProps(E, pixelData, dataW, F, muReg, convStruct, OptParams);
                   if (VERBOSE)
                       DeltaP = sum(sum(abs(P-newP)));
                    DeltaF = sum(sum(abs(F-newF)));
                        fprintf('Step for endmember %i error (DeltaError = 9.6f, eta = %9.6f)\n', j, Error-newError, eta);
                        fprintf('Changes in Proportions DeltaP = %12.6f    DeltaF = %12.6f\n', DeltaP, DeltaF);
                        figure(j);
                        plot(squeeze(tempEndmembers(:, j)), 'b', 'linewidth', 2);
                        hold on;
                        plot(squeeze(E(:, j)), 'r', 'linewidth', 2);
                        title('Old Endmember in Blue.  New Endmember in Red');
                        drawnow
                        hold off
                    end

                if (newError < Error) && (PASS == 1)
                    DeltaP = sum(sum(abs(P-newP)));
                    DeltaF = sum(sum(abs(F-newF)));
                    if (VERBOSE)
                        fprintf('Step for endmember %i reduced error (DeltaError = %2.22f, eta = %2.22f)\n', j, Error-NewError, eta);
                        fprintf('Changes in Proportions DeltaP = %12.6f    DeltaF = %12.6f\n', DeltaP, DeltaF);
                        figure(j);
                        plot(squeeze(tempEndmembers(:, j)), 'b', 'linewidth', 2);
                        hold on;
                        plot(squeeze(E(:, j)), 'r', 'linewidth', 2);
                        title('Old Endmember in Blue.  New Endmember in Red');
                        drawnow
                        hold off
                    end
                    P      = newP;
                    F      = newF;
                    RSSsum = newRSSsum;
                    Error  = newError;
                    E(:,j) = tempEndmembers(:,j);
                    newStep = 1;
                    Estep   = 1;
                    break;
                elseif PASS == 1
                end
                eta = eta/learningDivide;
                fprintf('Learning rate is %f\n', eta);
            end
        end
        if Estep == 0;
            exitReason = 2;
            break;
        end
        if prevError - Error < 1e-7
            exitReason = 3;
            break;
        end
    end
end
Error=RSSsum;

end